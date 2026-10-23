"""Operator-only, synthetic Codex Cloud proof. No phone server or private scan input."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys

from .adapters import OfficialCodexRunner
from .contracts import Principal, Problem, canonical, digest, identifier, validate_document
from .service import Service


RESULT_LIMIT = 256 * 1024
FIXTURE = {
    'format': 'synthetic-room-evidence/1', 'units': 'meters', 'up': '+Y',
    'floorY': 0, 'roomWidth': 4.6, 'roomDepth': 3.8, 'roomHeight': 2.7,
    'wallThickness': .12, 'floorThickness': .1,
    'tableBounds': {'min': [-.4, 0, -.6], 'max': [1.2, .8, .3]},
}
SCAN = {'kind': 'synthetic', 'assetID': 'cloud-smoke-v1', 'sha256': digest(FIXTURE)}


def expected_geometry():
    """Independent acceptance oracle, not supplied as the Cloud model output."""
    f = FIXTURE
    low, high = f['tableBounds']['min'], f['tableBounds']['max']
    return {
        'floor': ([0, -f['floorThickness'] / 2, 0], [f['roomWidth'], f['floorThickness'], f['roomDepth']]),
        'back': ([0, f['roomHeight'] / 2, -f['roomDepth'] / 2], [f['roomWidth'], f['roomHeight'], f['wallThickness']]),
        'side': ([-f['roomWidth'] / 2, f['roomHeight'] / 2, 0], [f['wallThickness'], f['roomHeight'], f['roomDepth']]),
        'table': ([(a + b) / 2 for a, b in zip(low, high)], [b - a for a, b in zip(low, high)]),
    }


def validate_geometry(document):
    validate_document(document)
    objects = {o['id']: o for o in document['objects']}
    expected = expected_geometry()
    if objects.keys() != expected.keys():
        raise Problem('invalid_model', 'Synthetic result must contain exactly the four measured objects.', 400)
    for key, (position, size) in expected.items():
        for field, values in [('position', position), ('size', size)]:
            if any(abs(a - b) > 1e-6 for a, b in zip(objects[key][field], values)):
                raise Problem('invalid_model', 'Returned geometry does not match the synthetic measurements.', 400)
    return document


def read_added_json(patch, path):
    """Accept one new, regular JSON file; never apply a patch or run generated code."""
    if not isinstance(patch, str) or len(patch.encode()) > RESULT_LIMIT:
        raise Problem('invalid_model', 'Cloud result exceeds the bounded JSON contract.', 400)
    lines = patch.splitlines()
    if not lines or lines.pop(0) != f'diff --git a/{path} b/{path}':
        raise Problem('invalid_model', 'Cloud diff must contain only the expected result file.', 400)
    if not lines or lines.pop(0) != 'new file mode 100644':
        raise Problem('invalid_model', 'Cloud result must be a new regular data file.', 400)
    if lines and lines[0].startswith('index '):
        if not re.fullmatch(r'index 0+\.\.[0-9a-f]+', lines.pop(0)):
            raise Problem('invalid_model', 'Invalid new-file diff header.', 400)
    if lines[:2] != ['--- /dev/null', f'+++ b/{path}']:
        raise Problem('invalid_model', 'Unexpected Cloud result path.', 400)
    lines = lines[2:]
    match = re.fullmatch(r'@@ -0,0 \+1(?:,(\d+))? @@', lines.pop(0)) if lines else None
    if not match:
        raise Problem('invalid_model', 'Expected one complete added-file hunk.', 400)
    count = int(match[1] or '1')
    if lines and lines[-1] == '\\ No newline at end of file':
        lines.pop()
    if len(lines) != count or not all(line.startswith('+') for line in lines):
        raise Problem('invalid_model', 'Unexpected changes outside the result data.', 400)
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('duplicate key')
            result[key] = value
        return result
    try:
        return json.loads('\n'.join(line[1:] for line in lines), object_pairs_hook=unique_object)
    except (ValueError, RecursionError):
        raise Problem('invalid_model', 'Cloud output is not unambiguous JSON.', 400) from None


class SyntheticDiffTransfer:
    """Public synthetic fixture only. This is NOT the private transfer gateway."""
    def __init__(self, read_diff, job_for_task):
        self.read_diff, self.job_for_task = read_diff, job_for_task

    @staticmethod
    def check_scan(scan):
        if scan != SCAN:
            raise Problem('synthetic_only', 'This proof accepts only its built-in public synthetic fixture.', 400)

    def prompt(self, job_id, scan):
        self.check_scan(scan)
        identifier(job_id)
        return f'''Reconstruct this public synthetic room as bounded JSON data, not source code.
This is an explicitly authorized one-attempt Codex Cloud integration test.
Read .agents/skills/scan-to-threejs/SKILL.md for measurement conventions.
Use only the measurement evidence below. Do not use private files, credentials,
external services, network downloads, photos or repository demo assets.
Do not commit, push, open a PR, deploy, publish, or modify existing files.

Evidence (meters, +Y up, floor zero): {canonical(FIXTURE)}
Construct exactly four axis-aligned boxes with IDs floor, back, side, table.
The floor is centered on X/Z and its top is floorY. Back wall center plane is
z=-roomDepth/2 and side wall center plane is x=-roomWidth/2; both rise from
floor zero to roomHeight. The table fills tableBounds. Derive centers and sizes.
Use editable-room/1: {{"format":"editable-room/1","label":"Synthetic Cloud studio",
"objects":[{{"id":"...","label":"...","kind":"box","position":[x,y,z],
"size":[width,height,depth],"color":"#RRGGBB"}}]}}.
No extra fields, URLs, scripts or assets. Choose simple plausible colors.

Create exactly ONE new regular file model-results/{job_id}.json with this envelope:
{{"format":"synthetic-cloud-result/1","jobID":"{job_id}",
"scanSHA256":"{scan['sha256']}","document":<your editable-room/1 document>}}
Leave this file as the task's visible diff. Use git add -N for this output only
if needed to make it visible in git diff. Do not change any other path.
The caller attempts to retrieve that diff through the official client and
validates it as data without applying it. Workspace visibility does not guarantee
that Cloud will serialize a result diff. State any inability to complete instead of faking output.
'''

    def read_result(self, task_id, scan):
        self.check_scan(scan)
        job_id = identifier(self.job_for_task(task_id))
        result = read_added_json(self.read_diff(task_id), f'model-results/{job_id}.json')
        if (not isinstance(result, dict) or set(result) != {'format', 'jobID', 'scanSHA256', 'document'}
                or result['format'] != 'synthetic-cloud-result/1' or result['jobID'] != job_id
                or result['scanSHA256'] != scan['sha256']):
            raise Problem('invalid_model', 'Synthetic output is not bound to this job and input.', 400)
        document = validate_geometry(result['document'])
        # Task binding comes from the official diff request and durable journal, not
        # an untrusted model's claim about its own task ID. Private gateway remains gated.
        return {'format': 'reconstruction-result/1', 'taskID': task_id,
                'scanSHA256': scan['sha256'], 'documentSHA256': digest(document), 'document': document}


def secure_state_directory(directory):
    """Keep SQLite and official-client logs under a private, stable POSIX owner boundary."""
    requested = Path(os.path.abspath(Path(directory).expanduser()))
    try:
        if requested.is_symlink():
            raise ValueError()
        parent = requested.parent.resolve(strict=True)
        for ancestor in [parent, *parent.parents]:
            info = ancestor.stat()
            # Root's sticky temp directories are safe parents of an owner-only entry;
            # non-sticky shared or foreign-owned parents could swap it underneath us.
            shared = info.st_mode & 0o022
            if info.st_uid not in (0, os.getuid()) or (shared and not (info.st_uid == 0 and info.st_mode & stat.S_ISVTX)):
                raise ValueError()
        path = parent / requested.name
        try:
            path.mkdir(mode=0o700)
        except FileExistsError:
            pass
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            info = os.fstat(fd)
            if info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise ValueError()
            for name in ('state.sqlite', 'state.sqlite-wal', 'state.sqlite-shm', 'state.sqlite-journal', 'error.log'):
                try:
                    entry = os.stat(name, dir_fd=fd, follow_symlinks=False)
                except FileNotFoundError:
                    continue
                if not stat.S_ISREG(entry.st_mode) or entry.st_uid != os.getuid() or entry.st_nlink != 1:
                    raise ValueError()
        finally:
            os.close(fd)
        return path
    except (OSError, ValueError):
        raise Problem('unsafe_state_directory', 'Use an owner-only nonsymlink state directory under trusted parents; existing journal/log files must be owned regular files.', 400) from None


class SmokeRun:
    """Restartable journal; submit is explicit, poll can never submit a task."""
    principal = Principal('synthetic-cloud-operator', can_model=True)
    room = 'cloud-smoke'

    def __init__(self, directory, environment, branch, binary, run=None):
        self.directory = secure_state_directory(directory)
        if not environment.strip() or not branch.strip():
            raise ValueError('Explicit authorized environment and branch required')
        transfer = SyntheticDiffTransfer(self.read_diff, self.job_for_task)
        kwargs = {'run': run} if run else {}
        self.runner = OfficialCodexRunner(binary, environment, branch, str(self.directory), transfer, **kwargs)
        self.service = Service(self.directory / 'state.sqlite', self.runner)
        config = canonical({'format': 1, 'environment': environment, 'branch': branch, 'scan': SCAN})
        with self.service.db() as db:
            db.execute('CREATE TABLE IF NOT EXISTS smoke_config(id INTEGER PRIMARY KEY CHECK(id=1), config TEXT)')
            row = db.execute('SELECT config FROM smoke_config WHERE id=1').fetchone()
            if row and row[0] != config:
                raise Problem('run_config_changed', 'Reuse the original environment/branch/input for this journal.', 409)
            db.execute('INSERT OR IGNORE INTO smoke_config VALUES(1,?)', (config,))
        self.service.register_scan(self.principal, self.room, 'fixture', SCAN)

    def snapshot(self):
        return self.service.snapshot(self.principal, self.room)

    def preflight(self):
        # A read-only operation before reservation; missing environment/auth cannot
        # leave a queued task. Never auto-select another repository's environment.
        try:
            text = self.runner._call(['list', '--env', self.runner.environment, '--json', '--limit', '1'])
            value = json.loads(text)
            if not isinstance(value, dict) or not isinstance(value.get('tasks'), list):
                raise ValueError()
        except (Problem, ValueError):
            raise Problem('cloud_environment_unavailable', 'Official client could not verify the selected environment. Use existing authorized access or obtain scoped setup approval; no task submitted.', 503) from None

    def submit(self):
        state = self.snapshot()
        if state['jobs']:
            # A crash before the transactional claim is known not to have submitted.
            # Only explicit submit resumes queued work; poll never does.
            return self.service.advance(self.principal, self.room) if state['jobs'][0]['state'] == 'queued' else state
        self.preflight()
        self.service.command(self.principal, self.room, {'id': 'cloud-smoke-once', 'kind': 'model', 'scanID': 'fixture'})
        return self.service.advance(self.principal, self.room)

    def poll(self):
        state = self.snapshot()
        if state['jobs'] and state['jobs'][0]['state'] == 'running':
            state = self.service.advance(self.principal, self.room)
        return state

    def job_for_task(self, task_id):
        jobs = [j for j in self.snapshot()['jobs'] if j['taskID'] == task_id]
        if len(jobs) != 1:
            raise Problem('invalid_model', 'Task is not bound to this journal.', 400)
        return jobs[0]['id']

    def read_diff(self, task_id):
        if not re.fullmatch(r'task_[A-Za-z0-9_-]+', task_id):
            raise Problem('invalid_task', 'Invalid task identifier.', 400)
        # This is a probe of an unproven backend serialization boundary, not a
        # guaranteed artifact channel. READY never authorizes inventing a result
        # or spending again when the backend has not exposed its diff.
        try:
            patch = self.runner._call(['diff', task_id, '--attempt', '1'])
        except Problem:
            patch = ''
        if not patch.strip():
            raise Problem('cloud_result_unavailable', 'Cloud result diff is unavailable; no revision accepted. Poll this same task or inspect it in Codex. Do not resubmit.', 503)
        return patch

    def reconcile(self, task_id):
        state = self.snapshot()
        if len(state['jobs']) != 1 or not re.fullmatch(r'task_[A-Za-z0-9_-]+', task_id):
            raise Problem('invalid_task', 'Expected one ambiguous job and a verified task ID.', 400)
        self.service.reconcile(self.principal, self.room, state['jobs'][0]['id'], task_id)
        return self.snapshot()

    def report(self, state):
        revisions = state['revisions']
        return {'mode': 'official-client-synthetic-proof', 'environment': self.runner.environment,
                'branch': self.runner.branch, 'scanSHA256': SCAN['sha256'], 'jobs': state['jobs'],
                'verified': bool(revisions), 'revisions': revisions,
                'publicationEnabled': False, 'phoneConnected': False}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['plan', 'check', 'submit', 'poll', 'show', 'reconcile'])
    parser.add_argument('--state-dir', type=Path, required=True, help='Private operator scratch directory outside any Git checkout')
    parser.add_argument('--environment', required=True, help='Explicit existing authorized environment ID or label')
    parser.add_argument('--branch', required=True)
    parser.add_argument('--codex', default='codex')
    parser.add_argument('--verified-task-id', help='Only reconcile after checking job correlation in official Cloud UI')
    args = parser.parse_args(argv)
    # Avoid storing diagnostic logs or generated results inside the public checkout.
    directory = args.state_dir.absolute()
    resolved = directory.resolve()
    if any((p / '.git').exists() for p in [resolved, *resolved.parents]):
        parser.error('--state-dir must be outside every Git checkout')
    binary = shutil.which(args.codex)
    if not binary:
        parser.error('Official Codex client is not installed at the selected path')
    binary = str(Path(binary).resolve())
    try:
        run = SmokeRun(directory, args.environment, args.branch, binary)
        if args.action == 'plan':
            print(run.runner.transfer.prompt('preview', SCAN)); return 0
        if args.action == 'check':
            run.preflight(); state = run.snapshot()
        elif args.action == 'submit':
            state = run.submit()
        elif args.action == 'poll':
            state = run.poll()
        elif args.action == 'reconcile':
            if not args.verified_task_id:
                parser.error('--verified-task-id is required for reconcile')
            state = run.reconcile(args.verified_task_id)
        else:
            state = run.snapshot()
        print(json.dumps(run.report(state), indent=2, allow_nan=False))
        return 2 if state['jobs'] and state['jobs'][0]['state'] in ('failed', 'reconciling', 'submitting') else 0
    except (Problem, ValueError) as error:
        print(json.dumps({'error': getattr(error, 'code', 'invalid_config'), 'message': str(error)}), file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
