"""Official-client boundary. No OAuth implementation, token inspection or API billing."""
import re
import subprocess
from .contracts import Problem, TaskProgress, digest, synthetic_document, validate_document


class GatedRunner:
    def submit(self, job_id, scan):
        raise Problem('cloud_setup_required', 'An authorized remote launcher and private transfer gateway are required.', 503)
    def status(self, task_id):
        raise Problem('cloud_setup_required', 'Cloud launcher is not configured.', 503)
    def result(self, task_id, scan):
        raise Problem('transfer_required', 'Private output transport is not configured.', 503)


class GatedPublisher:
    def publish(self, request_id, room_id, revision, expected):
        raise Problem('site_setup_required', 'A pre-created private ChatGPT Site and verified publisher are required.', 503)


class OfficialCodexRunner:
    """Production needs separately scoped deployment/auth/transfer approval.

    An operator may prove synthetic jobs with existing authorized local client access.
    That proof does not connect the phone or authorize private scan transfer.

    The official binary owns ChatGPT subscription authentication. These calls do not
    create credentials, select a model, upload ZIPs, apply patches or execute output.
    The remote host can be Linux. The working directory is an operator-owned checkout.
    """
    def __init__(self, binary, environment, branch, working_directory, transfer, run=subprocess.run):
        if not all((binary, environment, branch, working_directory, transfer)):
            raise ValueError('Explicit launcher, environment, branch, checkout and private gateway required')
        self.binary, self.environment, self.branch = binary, environment, branch
        self.cwd, self.transfer, self.run = working_directory, transfer, run

    def _call(self, args, prompt=None, status=False):
        try:
            result = self.run([self.binary, 'cloud', *args], input=prompt, text=True,
                              capture_output=True, timeout=90, cwd=self.cwd, check=False)
        except (OSError, subprocess.TimeoutExpired):
            # The process might have submitted before timing out. Never auto-submit again.
            raise Problem('cloud_outcome_unknown', 'Cloud outcome needs reconciliation; no new task was requested.') from None
        if result.returncode and not (status and result.returncode == 1):
            # CLI stderr can contain paths or auth details; do not return it to clients/logs.
            raise Problem('cloud_outcome_unknown', 'Official client did not confirm the operation; reconcile before retrying.')
        return result.stdout

    def submit(self, job_id, scan):
        prompt = self.transfer.prompt(job_id, scan)
        output = self._call(['exec', '--env', self.environment, '--branch', self.branch, '--attempts', '1', '-'], prompt)
        matches = re.findall(r'https://chatgpt\.com/(?:codex/tasks|s)/(task_[A-Za-z0-9_-]+)', output)
        if len(set(matches)) != 1:
            raise Problem('cloud_outcome_unknown', 'Official client response was not recognized; reconcile without resubmitting.')
        return matches[0]

    def status(self, task_id):
        if not re.fullmatch(r'task_[A-Za-z0-9_-]+', task_id):
            raise Problem('invalid_task', 'Invalid cloud task identifier.', 400)
        output = self._call(['status', task_id], status=True)
        # CLI is experimental. Unknown output is NOT completion or failure.
        label = re.search(r'^\[(PENDING|READY|APPLIED|ERROR)\]', output, re.MULTILINE)
        return TaskProgress({'PENDING': 'running', 'READY': 'complete', 'APPLIED': 'complete', 'ERROR': 'failed'}.get(label[1] if label else '', 'unknown'))

    def result(self, task_id, scan):
        result = self.transfer.read_result(task_id, scan)
        if (not isinstance(result, dict) or set(result) != {'format', 'taskID', 'scanSHA256', 'documentSHA256', 'document'}
                or result['format'] != 'reconstruction-result/1' or result['taskID'] != task_id
                or result['scanSHA256'] != scan['sha256'] or result['documentSHA256'] != digest(result['document'])):
            raise Problem('invalid_model', 'Output provenance or digest does not match this task and scan.', 400)
        return validate_document(result['document'])


class SyntheticRunner:
    def submit(self, job_id, scan):
        if scan['kind'] != 'synthetic':
            raise Problem('synthetic_only', 'Demo runner accepts synthetic evidence only.', 400)
        return 'synthetic_' + job_id
    def status(self, task_id):
        return TaskProgress('complete')
    def result(self, task_id, scan):
        return synthetic_document()


class SyntheticPublisher:
    def publish(self, request_id, room_id, revision, expected):
        # The service commits the local pointer after this acknowledgement. No external publication.
        return '/?room=' + room_id
