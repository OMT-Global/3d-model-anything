import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from model_service.adapters import OfficialCodexRunner, SyntheticRunner, SyntheticPublisher
from model_service.contracts import Principal, Problem, TaskProgress, digest, synthetic_document, validate_document
from model_service.http import Application
from model_service.service import Service


class CountingRunner(SyntheticRunner):
    submissions = 0
    def submit(self, *args):
        self.submissions += 1
        return super().submit(*args)


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'state.sqlite'
        self.runner = CountingRunner()
        self.service = Service(self.path, self.runner, SyntheticPublisher(), synthetic=True)
        self.user = Principal('owner', True, True)
        self.other = Principal('other', True, True)
        self.descriptor = {'kind': 'synthetic', 'assetID': 'fixture', 'sha256': digest({'synthetic': True})}
        self.service.register_scan(self.user, 'room', 'scan', self.descriptor)

    def command(self, kind, key=None, **kwargs):
        return self.service.command(self.user, 'room', {'id': key or kind, 'kind': kind, **kwargs})

    def ready(self):
        self.command('model', scanID='scan')
        self.service.advance(self.user, 'room')
        return self.service.advance(self.user, 'room')['revisions'][-1]

    def test_repeated_and_concurrent_model_requests_survive_restart(self):
        with ThreadPoolExecutor(8) as pool:
            states = list(pool.map(lambda _: self.command('model', scanID='scan'), range(20)))
        self.assertEqual(len({s['jobs'][0]['id'] for s in states}), 1)
        self.service = Service(self.path, self.runner, SyntheticPublisher(), synthetic=True)
        with ThreadPoolExecutor(8) as pool:
            list(pool.map(lambda _: self.service.advance(self.user, 'room'), range(20)))
        state = self.service.snapshot(self.user, 'room')
        self.assertEqual(self.runner.submissions, 1)
        self.assertEqual(len(state['revisions']), 1)
        with self.assertRaises(Problem):
            self.command('model', scanID='different')

    def test_unknown_submit_never_resubmits(self):
        class LostResponse(CountingRunner):
            def submit(self, *args):
                super().submit(*args)
                raise TimeoutError('lost acknowledgement')
        self.runner = LostResponse(); self.service.runner = self.runner
        state = self.command('model', scanID='scan')
        for _ in range(5):
            self.service.advance(self.user, 'room')
            self.command('model', scanID='scan')
        self.assertEqual(self.runner.submissions, 1)
        self.assertEqual(self.service.snapshot(self.user, 'room')['jobs'][0]['state'], 'reconciling')
        with self.assertRaises(Problem):
            self.command('model', key='new-key', scanID='scan')
        self.service.reconcile(self.user, 'room', state['jobs'][0]['id'], 'task_verified')
        self.assertEqual(self.service.advance(self.user, 'room')['jobs'][0]['state'], 'ready')

    def test_process_death_after_claim_does_not_duplicate(self):
        class Crash(CountingRunner):
            def submit(self, *args):
                super().submit(*args)
                raise SystemExit()
        self.service.runner = Crash()
        self.command('model', scanID='scan')
        with self.assertRaises(SystemExit): self.service.advance(self.user, 'room')
        restarted = Service(self.path, self.runner, SyntheticPublisher())
        self.assertEqual(restarted.advance(self.user, 'room')['jobs'][0]['state'], 'submitting')
        self.assertEqual(self.runner.submissions, 0)

    def test_edit_approval_and_last_working_publication(self):
        original = self.ready()
        with self.assertRaises(Problem): self.command('publish', revisionID=original['id'])
        self.command('approve', revisionID=original['id'])
        self.command('publish', revisionID=original['id'])
        self.service.advance(self.user, 'room')
        doc = synthetic_document(); doc['objects'][-1]['position'][0] = 1.2
        revised = self.command('edit', baseRevisionID=original['id'], document=doc)['revisions'][-1]
        self.assertFalse(revised['approved'])
        self.assertEqual(self.service.published_document(self.user, 'room')['sha256'], original['sha256'])
        with self.assertRaises(Problem): self.command('publish', 'publish2', revisionID=revised['id'])
        self.command('approve', 'approve2', revisionID=revised['id'])
        self.command('publish', 'publish2', revisionID=revised['id'])
        class Outage:
            def publish(self, *args): raise TimeoutError()
        self.service.publisher = Outage()
        for _ in range(3): self.service.advance(self.user, 'room')
        self.assertEqual(self.service.published_document(self.user, 'room')['id'], original['id'])
        self.service.publisher = SyntheticPublisher()
        self.service.advance(self.user, 'room')
        state = self.command('publish', 'publish2', revisionID=revised['id'])
        self.assertEqual(len(state['publications']), 2)
        self.assertEqual(state['publishedRevisionID'], revised['id'])
        self.assertEqual(state['revisions'][0]['document'], original['document'])
        self.assertEqual(state['revisions'][1]['parentID'], original['id'])
        with self.assertRaises(Problem):
            self.service.register_scan(self.user, 'room', 'scan', {**self.descriptor, 'sha256': 'a' * 64})

    def test_failed_job_can_be_explicitly_retried_with_new_intent(self):
        self.command('model', scanID='scan'); self.service.advance(self.user, 'room')
        self.runner.status = lambda _: TaskProgress('failed')
        self.assertEqual(self.service.advance(self.user, 'room')['jobs'][0]['state'], 'failed')
        self.command('model', scanID='scan')  # retry same HTTP request is a no-op
        self.assertEqual(len(self.service.snapshot(self.user, 'room')['jobs']), 1)
        self.command('model', key='explicit-retry', scanID='scan')
        self.assertEqual(len(self.service.snapshot(self.user, 'room')['jobs']), 2)

    def test_unknown_status_and_bad_output_cannot_create_revision(self):
        self.command('model', scanID='scan'); self.service.advance(self.user, 'room')
        self.runner.status = lambda _: TaskProgress('unknown')
        self.assertEqual(self.service.advance(self.user, 'room')['revisions'], [])
        self.runner.status = lambda _: TaskProgress('complete')
        self.runner.result = lambda *_: {'script': 'do not execute'}
        self.assertEqual(self.service.advance(self.user, 'room')['revisions'], [])

    def test_ownership_and_spend_authorization(self):
        self.ready()
        self.assertEqual(self.service.snapshot(self.other, 'room')['revisions'], [])
        with self.assertRaises(Problem): self.service.published_document(self.other, 'room')
        with self.assertRaises(Problem):
            self.service.command(Principal('owner'), 'room', {'id': 'no', 'kind': 'model', 'scanID': 'scan'})
        with self.assertRaises(Problem):
            self.service.command(self.other, 'room', {'id': 'no', 'kind': 'model', 'scanID': 'scan'})

    def test_live_adapters_gate_before_work_is_reserved(self):
        gated = Service(self.path)
        with self.assertRaisesRegex(Problem, 'not configured'):
            gated.command(self.user, 'room', {'id': 'model', 'kind': 'model', 'scanID': 'scan'})
        self.assertEqual(gated.snapshot(self.user, 'room')['jobs'], [])

    def request(self, app, path, method='GET', body=None, **headers):
        raw = json.dumps(body).encode() if body is not None else b''
        env = {'REQUEST_METHOD': method, 'PATH_INFO': path, 'CONTENT_TYPE': 'application/json',
               'CONTENT_LENGTH': str(len(raw)), 'wsgi.input': io.BytesIO(raw), 'wsgi.url_scheme': 'https', 'HTTP_HOST': 'private.example', **headers}
        response = []
        data = b''.join(app(env, lambda status, hdr: response.append((status, dict(hdr)))))
        return response[0], data

    def test_all_routes_and_assets_require_auth(self):
        viewer = Path(self.tmp.name) / 'viewer'; viewer.mkdir(); (viewer/'index.html').write_text('protected')
        app = Application(self.service, viewer=viewer)
        for path in ('/', '/index.html', '/asset.glb', '/v1/rooms/room', '/v1/rooms/room/published', '/v1/capabilities'):
            (status, headers), _ = self.request(app, path)
            self.assertTrue(status.startswith('401')); self.assertEqual(headers['Cache-Control'], 'no-store')
        app = Application(self.service, lambda _: self.user, viewer)
        self.assertTrue(self.request(app, '/')[0][0].startswith('200'))
        self.assertTrue(self.request(app, '/../state.sqlite')[0][0].startswith('404'))
        self.assertTrue(self.request(app, '/v1/rooms/room/commands', 'POST', {'id': 'model', 'kind': 'model', 'scanID': 'scan'}, HTTP_ORIGIN='https://evil.example')[0][0].startswith('403'))
        self.assertTrue(self.request(app, '/v1/rooms/room/commands', 'POST', {'id': 'model', 'kind': 'model', 'scanID': 'scan'})[0][0].startswith('200'))
        self.assertEqual(self.runner.submissions, 0)  # GETs/command reservation do not launch a worker.

    def test_mobile_service_rejects_legacy_repository_runner_before_any_call(self):
        def forbidden_call(*args, **kwargs):
            self.fail('Constructing the mobile service must not invoke the Cloud client')
        runner = OfficialCodexRunner('/official/codex', 'developer-env', 'feature', self.tmp.name,
                                     SimpleNamespace(), forbidden_call)
        service = Service(self.path, runner)
        with self.assertRaisesRegex(ValueError, 'repo-free provider'):
            Application(service, lambda _: self.user)
        self.assertEqual(service.snapshot(self.user, 'room')['jobs'], [])

    def test_capabilities_do_not_mistake_local_demo_or_permissions_for_repo_free_cloud(self):
        for service in (self.service, Service(self.path)):
            app = Application(service, lambda _: self.user)
            (status, _), payload = self.request(app, '/v1/capabilities')
            self.assertTrue(status.startswith('200'))
            capabilities = json.loads(payload)
            self.assertTrue(capabilities['model'])  # Permission is distinct from availability.
            self.assertFalse(capabilities['endUserRepositoryRequired'])
            self.assertFalse(capabilities['repoFreeCloudAvailable'])

    def test_http_end_to_end_contract(self):
        app = Application(self.service, lambda _: self.user)
        def req(suffix, body):
            (status, _), payload = self.request(app, '/v1/rooms/room/' + suffix, 'POST', body)
            self.assertTrue(status.startswith('200'), payload)
            return json.loads(payload)
        req('commands', {'id': 'model', 'kind': 'model', 'scanID': 'scan'})
        req('advance', {}); state = req('advance', {})
        revision = state['revisions'][0]['id']
        req('commands', {'id': 'approve', 'kind': 'approve', 'revisionID': revision})
        req('commands', {'id': 'publish', 'kind': 'publish', 'revisionID': revision})
        req('advance', {})
        self.assertTrue(self.request(app, '/v1/rooms/room/published')[0][0].startswith('200'))

    def test_document_rejects_executable_external_and_unbounded_fields(self):
        for mutation in (lambda d: d.update(script='unsafe'), lambda d: d['objects'][0].update(url='https://external.example'), lambda d: d['objects'][0].update(size=[-1, 1, 1]), lambda d: d['objects'][0].update(position=[float('nan'), 0, 0])):
            doc = synthetic_document(); mutation(doc)
            with self.assertRaises(Problem): validate_document(doc)


class OfficialClientTests(unittest.TestCase):
    def adapter(self, run):
        transfer = SimpleNamespace(prompt=lambda *_: 'Approved opaque transfer contract', read_result=lambda *_: synthetic_document())
        return OfficialCodexRunner('/official/codex', 'env-approved', 'feature-approved', '/approved/checkout', transfer, run)

    def test_command_uses_official_client_stdin_and_one_attempt(self):
        calls = []
        def run(args, **kwargs):
            calls.append((args, kwargs)); return SimpleNamespace(returncode=0, stdout='https://chatgpt.com/codex/tasks/task_abc\n')
        self.assertEqual(self.adapter(run).submit('job', {}), 'task_abc')
        args, kwargs = calls[0]
        self.assertEqual(args, ['/official/codex', 'cloud', 'exec', '--env', 'env-approved', '--branch', 'feature-approved', '--attempts', '1', '-'])
        self.assertEqual(kwargs['input'], 'Approved opaque transfer contract')
        self.assertNotIn('shell', kwargs)

    def test_result_envelope_binds_task_input_and_document(self):
        runner = self.adapter(lambda *_, **__: None)
        document = synthetic_document()
        scan = {'sha256': 'a' * 64}
        result = {'format': 'reconstruction-result/1', 'taskID': 'task_abc', 'scanSHA256': scan['sha256'], 'documentSHA256': digest(document), 'document': document}
        runner.transfer.read_result = lambda *_: result
        self.assertEqual(runner.result('task_abc', scan), document)
        for field in ('taskID', 'scanSHA256', 'documentSHA256'):
            old = result[field]; result[field] = 'wrong'
            with self.assertRaises(Problem): runner.result('task_abc', scan)
            result[field] = old

    def test_nonzero_status_is_official_pending_or_error_not_transport_failure(self):
        for label, code, expected in [('PENDING', 1, 'running'), ('READY', 0, 'complete'), ('ERROR', 1, 'failed'), ('APPLIED', 1, 'complete'), ('FUTURE', 0, 'unknown')]:
            runner = self.adapter(lambda *_, **__: SimpleNamespace(returncode=code, stdout=f'[{label}] title\n'))
            self.assertEqual(runner.status('task_abc').state, expected)

    def test_ambiguous_submission_and_timeout_require_reconciliation(self):
        for output in ('', 'https://evil.example/task_abc', 'https://chatgpt.com/codex/tasks/task_a\nhttps://chatgpt.com/codex/tasks/task_b'):
            with self.assertRaises(Problem): self.adapter(lambda *_, **__: SimpleNamespace(returncode=0, stdout=output)).submit('job', {})
        def timeout(*_, **__): raise subprocess.TimeoutExpired('codex', 90)
        with self.assertRaises(Problem): self.adapter(timeout).submit('job', {})


if __name__ == '__main__': unittest.main()
