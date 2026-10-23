import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from model_service.cloud_smoke import FIXTURE, SCAN, SmokeRun, SyntheticDiffTransfer, expected_geometry, read_added_json, validate_geometry, main, secure_state_directory
from model_service.contracts import Problem, canonical, synthetic_document


def measured_document():
    return {'format': 'editable-room/1', 'label': 'Synthetic Cloud studio', 'objects': [
        {'id': key, 'label': key.title(), 'kind': 'box', 'position': position, 'size': size, 'color': '#ccbb99'}
        for key, (position, size) in expected_geometry().items()
    ]}


def patch_for(job='job1', document=None, **changes):
    value = {'format': 'synthetic-cloud-result/1', 'jobID': job, 'scanSHA256': SCAN['sha256'], 'document': document or measured_document(), **changes}
    lines = json.dumps(value, indent=2).splitlines()
    path = f'model-results/{job}.json'
    return f'diff --git a/{path} b/{path}\nnew file mode 100644\nindex 0000000..abc1234\n--- /dev/null\n+++ b/{path}\n@@ -0,0 +1,{len(lines)} @@\n' + '\n'.join('+' + line for line in lines) + '\n'


class TransferTests(unittest.TestCase):
    def transfer(self, patch):
        return SyntheticDiffTransfer(lambda _: patch, lambda _: 'job1')

    def test_known_dimensions_are_independent_of_local_demo(self):
        doc = measured_document()
        objects = {o['id']: o for o in doc['objects']}
        self.assertEqual(objects['floor']['size'], [4.6, .1, 3.8])
        self.assertAlmostEqual(objects['table']['position'][0], .4)
        self.assertAlmostEqual(objects['table']['size'][2], .9)
        self.assertEqual(validate_geometry(doc), doc)
        with self.assertRaises(Problem): validate_geometry(synthetic_document())

    def test_envelope_and_geometry_verified_without_applying_patch(self):
        result = self.transfer(patch_for()).read_result('task_live', SCAN)
        self.assertEqual(result['taskID'], 'task_live')
        self.assertEqual(result['document'], measured_document())
        self.assertEqual(result['scanSHA256'], SCAN['sha256'])

    def test_private_or_modified_fixture_never_enters_prompt_or_reader(self):
        transfer = self.transfer(patch_for())
        for scan in ({**SCAN, 'kind': 'private-bundle'}, {**SCAN, 'sha256': 'a' * 64}, {**SCAN, 'assetID': 'another'}):
            with self.assertRaises(Problem): transfer.prompt('job1', scan)
            with self.assertRaises(Problem): transfer.read_result('task_live', scan)
        self.assertIn(canonical(FIXTURE), transfer.prompt('job1', SCAN))

    def test_wrong_job_digest_schema_and_measurements_are_rejected(self):
        for changes in ({'jobID': 'other'}, {'scanSHA256': 'a' * 64}, {'format': 'other'}, {'extra': 'field'}):
            with self.assertRaises(Problem): self.transfer(patch_for(**changes)).read_result('task_live', SCAN)
        for mutation in (lambda d: d['objects'][0]['size'].__setitem__(0, 5),
                         lambda d: d['objects'][0].update(url='https://external.example'),
                         lambda d: d['objects'][0]['position'].__setitem__(0, float('nan'))):
            doc = measured_document(); mutation(doc)
            with self.assertRaises(Problem): self.transfer(patch_for(document=doc)).read_result('task_live', SCAN)

    def test_extra_paths_traversal_binary_symlink_executable_context_are_rejected(self):
        patch = patch_for()
        attacks = [patch + patch, patch.replace('model-results/job1.json', '../escape.json'),
                   patch.replace('100644', '120000'), patch.replace('100644', '100755'),
                   patch.replace('--- /dev/null', '--- a/model-results/job1.json'),
                   patch.replace('+{', ' {', 1), patch + 'GIT binary patch\n',
                   patch.replace('new file mode 100644\n', ''), patch + '\n', 'x' * (256 * 1024 + 1)]
        for attack in attacks:
            with self.subTest(attack=attack[:70]):
                with self.assertRaises(Problem): read_added_json(attack, 'model-results/job1.json')

    def test_accepts_actual_git_new_file_diff_without_applying_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '-q', directory], check=True)
            path = root / 'model-results' / 'job1.json'
            path.parent.mkdir()
            envelope = {'format': 'synthetic-cloud-result/1', 'jobID': 'job1', 'scanSHA256': SCAN['sha256'], 'document': measured_document()}
            path.write_text(json.dumps(envelope, indent=2) + '\n')
            subprocess.run(['git', '-C', directory, 'add', '-N', 'model-results/job1.json'], check=True)
            patch = subprocess.run(['git', '-C', directory, 'diff', '--no-ext-diff', '--no-color'], check=True, capture_output=True, text=True).stdout
            self.assertEqual(self.transfer(patch).read_result('task_test', SCAN)['document'], measured_document())

    def test_duplicate_keys_and_multiple_hunks_are_rejected(self):
        path = 'model-results/job1.json'
        prefix = f'diff --git a/{path} b/{path}\nnew file mode 100644\n--- /dev/null\n+++ b/{path}\n'
        for body in ['@@ -0,0 +1 @@\n+{"x":1,"x":2}\n', '@@ -0,0 +1 @@\n+{}\n@@ -0,0 +2 @@\n+{}\n']:
            with self.assertRaises(Problem): read_added_json(prefix + body, path)
        self.assertEqual(read_added_json(prefix + '@@ -0,0 +1 @@\n+{}\n\\ No newline at end of file\n', path), {})


class StateDirectoryTests(unittest.TestCase):
    def test_rejects_shared_directory_symlink_and_shared_parent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shared = root / 'shared'; shared.mkdir(mode=0o755)
            with self.assertRaises(Problem): secure_state_directory(shared)
            target = root / 'target'; target.mkdir(mode=0o700)
            link = root / 'link'; link.symlink_to(target, target_is_directory=True)
            with self.assertRaises(Problem): secure_state_directory(link)
            shared.chmod(0o777)
            with self.assertRaises(Problem): secure_state_directory(shared / 'child')
            self.assertFalse((shared / 'child').exists())

    def test_rejects_preplaced_symlink_and_hardlink_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); target = root / 'target'; target.write_text('preserve')
            log = root / 'error.log'; log.symlink_to(target)
            with self.assertRaises(Problem): secure_state_directory(root)
            log.unlink(); os.link(target, log)
            with self.assertRaises(Problem): secure_state_directory(root)
            self.assertEqual(target.read_text(), 'preserve')

    def test_creates_private_directory_and_preserves_existing_private_journal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'run'
            self.assertEqual(secure_state_directory(root), root.resolve())
            self.assertEqual(root.stat().st_mode & 0o777, 0o700)
            journal = root / 'state.sqlite'; journal.write_text('preserve')
            self.assertEqual(secure_state_directory(root), root.resolve())
            self.assertEqual(journal.read_text(), 'preserve')

    def test_cli_resolves_relative_binary_before_changing_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); binary = root / 'codex'; binary.write_text('#!/bin/sh\nexit 0\n'); binary.chmod(0o700)
            relative = os.path.relpath(binary)
            with patch('model_service.cloud_smoke.SmokeRun') as run, patch('builtins.print'):
                main(['plan', '--state-dir', str(root / 'state'), '--environment', 'env', '--branch', 'feature', '--codex', relative])
                self.assertEqual(run.call_args.args[3], str(binary.resolve()))


class JournalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.calls = []; self.job_id = None; self.fail_submit = False; self.missing_env = False; self.diff_failure = None
        self.run = SmokeRun(self.temp.name, 'env-approved', 'feat/scan-model-publish', '/official/codex', self.client)

    def client(self, args, **kwargs):
        self.calls.append(args)
        self.assertNotIn('shell', kwargs)
        action = args[2]
        if action == 'list':
            return SimpleNamespace(returncode=1 if self.missing_env else 0, stdout='{"tasks":[],"cursor":null}')
        if action == 'exec':
            prompt = kwargs['input']
            marker = 'model-results/'
            self.job_id = prompt.split(marker)[1].split('.json')[0]
            if self.fail_submit: raise subprocess.TimeoutExpired('codex', 90)
            return SimpleNamespace(returncode=0, stdout='https://chatgpt.com/codex/tasks/task_test\n')
        if action == 'status': return SimpleNamespace(returncode=0, stdout='[READY] Synthetic test\n')
        if action == 'diff':
            if self.diff_failure is not None:
                return SimpleNamespace(returncode=self.diff_failure, stdout='')
            return SimpleNamespace(returncode=0, stdout=patch_for(self.job_id))
        raise AssertionError(f'Unexpected official command: {action}')

    def test_plan_and_empty_poll_do_not_call_client(self):
        self.run.runner.transfer.prompt('preview', SCAN)
        self.assertEqual(self.run.poll()['jobs'], [])
        self.assertEqual(self.calls, [])

    def test_missing_environment_fails_before_any_task_reservation(self):
        self.missing_env = True
        with self.assertRaisesRegex(Problem, 'no task submitted'): self.run.submit()
        self.assertEqual(self.run.snapshot()['jobs'], [])
        self.assertFalse(any(c[2] == 'exec' for c in self.calls))

    def test_submit_restart_poll_import_one_revision_without_publishing(self):
        first = self.run.submit()
        self.assertEqual(first['jobs'][0]['taskID'], 'task_test')
        self.assertFalse(self.run.report(first)['verified'])
        self.run = SmokeRun(self.temp.name, 'env-approved', 'feat/scan-model-publish', '/official/codex', self.client)
        self.run.submit()
        final = self.run.poll()
        self.assertTrue(self.run.report(final)['verified'])
        self.assertEqual(final['revisions'][0]['origin'], 'codex-cloud')
        self.assertFalse(final['revisions'][0]['approved'])
        self.assertEqual(final['publications'], [])
        self.assertEqual(final['revisions'][0]['document'], measured_document())
        self.run.poll(); self.run.submit()
        self.assertEqual(len(self.run.snapshot()['revisions']), 1)
        self.assertEqual(sum(c[2] == 'exec' for c in self.calls), 1)

    def test_ready_without_serialized_diff_stays_unverified_without_resubmission(self):
        self.run.submit()
        for failure in (1, 0):
            self.diff_failure = failure
            state = self.run.poll()
            self.assertEqual(state['jobs'][0]['state'], 'running')
            self.assertIn('result diff is unavailable', state['jobs'][0]['message'])
            self.assertFalse(self.run.report(state)['verified'])
            self.assertEqual(state['revisions'], [])
            self.run.submit()
        self.run = SmokeRun(self.temp.name, 'env-approved', 'feat/scan-model-publish', '/official/codex', self.client)
        self.assertFalse(self.run.report(self.run.poll())['verified'])
        self.diff_failure = None
        self.assertTrue(self.run.report(self.run.poll())['verified'])
        self.assertEqual(sum(c[2] == 'exec' for c in self.calls), 1)
        self.assertEqual(len(self.run.snapshot()['revisions']), 1)

    def test_concurrent_submit_and_polls_cannot_duplicate_task_or_revision(self):
        with ThreadPoolExecutor(5) as pool: list(pool.map(lambda _: self.run.submit(), range(5)))
        with ThreadPoolExecutor(5) as pool: list(pool.map(lambda _: self.run.poll(), range(5)))
        self.assertEqual(sum(c[2] == 'exec' for c in self.calls), 1)
        self.assertEqual(len(self.run.snapshot()['revisions']), 1)

    def test_unknown_submit_never_resubmits_and_manual_binding_checks_output(self):
        self.fail_submit = True
        self.assertEqual(self.run.submit()['jobs'][0]['state'], 'reconciling')
        self.run.submit(); self.run.poll()
        self.assertEqual(sum(c[2] == 'exec' for c in self.calls), 1)
        self.run.reconcile('task_verified_by_operator')
        self.assertTrue(self.run.report(self.run.poll())['verified'])

    def test_reserved_but_unclaimed_job_requires_explicit_submit(self):
        self.run.service.command(self.run.principal, self.run.room, {'id': 'cloud-smoke-once', 'kind': 'model', 'scanID': 'fixture'})
        self.assertEqual(self.run.poll()['jobs'][0]['state'], 'queued')
        self.assertEqual(self.calls, [])
        self.assertEqual(self.run.submit()['jobs'][0]['state'], 'running')
        self.assertEqual(sum(c[2] == 'exec' for c in self.calls), 1)

    def test_journal_rejects_changed_environment_or_branch(self):
        self.run.submit()
        for env, branch in [('env-other', 'feat/scan-model-publish'), ('env-approved', 'main')]:
            with self.assertRaises(Problem): SmokeRun(self.temp.name, env, branch, '/official/codex', self.client)


if __name__ == '__main__': unittest.main()
