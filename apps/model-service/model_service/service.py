"""Durable single-node orchestration; SQLite transactions never span remote calls."""
from contextlib import contextmanager
import json
import sqlite3
import uuid
from .contracts import Problem, canonical, digest, identifier, validate_document
from .adapters import GatedRunner, GatedPublisher


def uid():
    return uuid.uuid4().hex


class Service:
    def __init__(self, database, runner=None, publisher=None, synthetic=False):
        self.database = str(database)
        self.runner = runner or GatedRunner()
        self.publisher = publisher or GatedPublisher()
        self.synthetic = synthetic
        with self.db() as db:
            db.executescript('''
              CREATE TABLE IF NOT EXISTS rooms(owner TEXT, id TEXT, state TEXT, PRIMARY KEY(owner,id));
              CREATE TABLE IF NOT EXISTS operations(owner TEXT, id TEXT, room TEXT, fingerprint TEXT, PRIMARY KEY(owner,id));
              CREATE TABLE IF NOT EXISTS scans(owner TEXT, id TEXT, room TEXT, descriptor TEXT, PRIMARY KEY(owner,id));
            ''')

    @contextmanager
    def db(self):
        db = sqlite3.connect(self.database, timeout=10)
        try:
            db.execute('BEGIN IMMEDIATE')
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    def _load(self, db, owner, room):
        identifier(room)
        row = db.execute('SELECT state FROM rooms WHERE owner=? AND id=?', (owner, room)).fetchone()
        return json.loads(row[0]) if row else {'roomID': room, 'jobs': [], 'revisions': [], 'publications': [], 'publishedRevisionID': None}

    def _save(self, db, owner, state):
        db.execute('INSERT OR REPLACE INTO rooms VALUES(?,?,?)', (owner, state['roomID'], canonical(state)))

    def snapshot(self, principal, room):
        with self.db() as db:
            return self._load(db, principal.subject, room)

    def register_scan(self, principal, room, scan_id, descriptor):
        """Called by a trusted input gateway AFTER authenticated, immutable upload verification.

        Opaque storage ID + hash only. No arbitrary URL fetch or filesystem path resolution.
        This function does not claim to implement transport of private scan files.
        """
        identifier(scan_id); identifier(room)
        if set(descriptor) != {'kind', 'sha256', 'assetID'} or descriptor['kind'] not in ('synthetic', 'private-bundle'):
            raise Problem('invalid_scan', 'Invalid sealed scan descriptor.', 400)
        identifier(descriptor['assetID'])
        if len(descriptor['sha256']) != 64 or any(c not in '0123456789abcdef' for c in descriptor['sha256']):
            raise Problem('invalid_scan', 'Expected SHA-256.', 400)
        with self.db() as db:
            row = db.execute('SELECT room,descriptor FROM scans WHERE owner=? AND id=?', (principal.subject, scan_id)).fetchone()
            if row and row != (room, canonical(descriptor)):
                raise Problem('immutable_scan', 'Original scan identity cannot be replaced.')
            db.execute('INSERT OR IGNORE INTO scans VALUES(?,?,?,?)', (principal.subject, scan_id, room, canonical(descriptor)))

    def command(self, principal, room, command):
        if not isinstance(command, dict) or not {'id', 'kind'} <= command.keys():
            raise Problem('invalid_command', 'A command ID and kind are required.', 400)
        key = identifier(command['id'])
        kind = command['kind']
        allowed = {'model': {'scanID'}, 'edit': {'baseRevisionID', 'document'}, 'approve': {'revisionID'}, 'publish': {'revisionID'}}
        if kind not in allowed or set(command) != {'id', 'kind'} | allowed[kind]:
            raise Problem('invalid_command', 'Unsupported command fields.', 400)
        if kind in ('model', 'edit') and not principal.can_model:
            raise Problem('forbidden', 'Model access and explicit usage authorization are required.', 403)
        if kind in ('approve', 'publish') and not principal.can_publish:
            raise Problem('forbidden', 'Publication authorization is required.', 403)
        with self.db() as db:
            fingerprint = digest(command)
            previous = db.execute('SELECT room,fingerprint FROM operations WHERE owner=? AND id=?', (principal.subject, key)).fetchone()
            state = self._load(db, principal.subject, room)
            if previous:
                if previous != (room, fingerprint):
                    raise Problem('idempotency_conflict', 'This request ID already belongs to a different operation.')
                return state
            if kind == 'model':
                scan = db.execute('SELECT descriptor FROM scans WHERE owner=? AND id=? AND room=?', (principal.subject, identifier(command['scanID']), room)).fetchone()
                if not scan:
                    raise Problem('scan_required', 'Upload and seal the selected scan through the approved private gateway first.', 409)
                if any(j['state'] in ('queued', 'submitting', 'running', 'reconciling') for j in state['jobs']):
                    raise Problem('job_active', 'Resume the existing job before starting another.')
                if isinstance(self.runner, GatedRunner):
                    raise Problem('cloud_setup_required', 'Remote launcher and private transport are not configured.', 503)
                state['jobs'].append({'id': uid(), 'requestID': key, 'scanID': command['scanID'], 'scan': json.loads(scan[0]),
                                      'state': 'queued', 'taskID': None, 'message': 'Queued', 'revisionID': None})
            elif kind == 'edit':
                base = self._revision(state, command['baseRevisionID'])
                doc = validate_document(command['document'])
                state['revisions'].append(self._new_revision(base['scanID'], doc, base['id'], 'edited'))
            elif kind == 'approve':
                self._revision(state, command['revisionID'])['approved'] = True
            elif kind == 'publish':
                rev = self._revision(state, command['revisionID'])
                if not rev['approved']:
                    raise Problem('approval_required', 'Review and approve this exact revision before publishing.')
                if any(p['state'] in ('queued', 'publishing') for p in state['publications']):
                    raise Problem('publish_active', 'Resume the current publication first.')
                if isinstance(self.publisher, GatedPublisher):
                    raise Problem('site_setup_required', 'Protected ChatGPT Site publication is not configured.', 503)
                state['publications'].append({'id': key, 'revisionID': rev['id'], 'expected': state['publishedRevisionID'], 'state': 'queued', 'url': None})
            db.execute('INSERT INTO operations VALUES(?,?,?,?)', (principal.subject, key, room, fingerprint))
            self._save(db, principal.subject, state)
            return state

    @staticmethod
    def _revision(state, revision_id):
        for rev in state['revisions']:
            if rev['id'] == revision_id:
                return rev
        raise Problem('not_found', 'Revision unavailable.', 404)

    @staticmethod
    def _new_revision(scan_id, document, parent, origin):
        return {'id': uid(), 'scanID': scan_id, 'parentID': parent, 'origin': origin,
                'document': document, 'sha256': digest(document), 'approved': False}

    def advance(self, principal, room):
        """Explicitly authenticated work tick. Read-only GET never spends usage.

        Claim before submit. A crash/ambiguous response leaves submitting/reconciling,
        which cannot be auto-resubmitted because Cloud has no proven idempotency key.
        """
        if principal.can_model:
            self._advance_job(principal, room)
        if principal.can_publish:
            self._advance_publication(principal, room)
        return self.snapshot(principal, room)

    def _advance_job(self, principal, room):
        owner = principal.subject
        with self.db() as db:
            state = self._load(db, owner, room)
            job = next((j for j in state['jobs'] if j['state'] in ('queued', 'running')), None)
            if not job:
                return
            submitting = job['state'] == 'queued'
            if submitting:
                job['state'], job['message'] = 'submitting', 'Submitting once through official client'
                self._save(db, owner, state)
        try:
            if submitting:
                task_id = self.runner.submit(job['id'], job['scan'])
                with self.db() as db:
                    state = self._load(db, owner, room)
                    current = next(j for j in state['jobs'] if j['id'] == job['id'])
                    current.update(taskID=task_id, state='running', message='Reconstruction in progress')
                    self._save(db, owner, state)
                return
            progress = self.runner.status(job['taskID'])
            if progress.state == 'running':
                return
            if progress.state == 'unknown':
                raise Problem('status_unknown', 'Cloud status is unrecognized. Refresh safely; do not start another job.')
            if progress.state == 'failed':
                raise Problem('job_failed', 'Cloud reported failure. Original scan and previous revisions are retained.')
            if progress.state != 'complete':
                raise Problem('status_unknown', 'Unrecognized runner state.')
            document = validate_document(self.runner.result(job['taskID'], job['scan']))
            with self.db() as db:
                state = self._load(db, owner, room)
                current = next(j for j in state['jobs'] if j['id'] == job['id'])
                if current['state'] != 'running':
                    return  # concurrent polls cannot append duplicate revisions
                rev = self._new_revision(job['scanID'], document, None, 'synthetic' if self.synthetic else 'codex-cloud')
                state['revisions'].append(rev)
                current.update(state='ready', revisionID=rev['id'], message='Ready to preview and edit')
                self._save(db, owner, state)
        except Exception as error:
            with self.db() as db:
                state = self._load(db, owner, room)
                current = next(j for j in state['jobs'] if j['id'] == job['id'])
                if current['state'] in ('submitting', 'running'):
                    code = error.code if isinstance(error, Problem) else 'adapter_error'
                    next_state = 'reconciling' if submitting else ('failed' if code in ('job_failed', 'invalid_model') else 'running')
                    current.update(state=next_state, message=str(error) if isinstance(error, Problem) else 'Adapter unavailable. Retry status without creating a new task.')
                    self._save(db, owner, state)

    def reconcile(self, principal, room, job_id, verified_task_id):
        """Operator-only hook, intentionally NOT routed in HTTP. Bind a verified existing task.

        Verify owner, environment and job correlation in official Cloud UI/list first.
        This does not launch anything; failed/unknown submits cannot be cleared via mobile.
        """
        if not principal.can_model:
            raise Problem('forbidden', 'Model authorization required.', 403)
        identifier(verified_task_id)
        with self.db() as db:
            state = self._load(db, principal.subject, room)
            job = next((j for j in state['jobs'] if j['id'] == job_id), None)
            if not job or job['state'] not in ('submitting', 'reconciling'):
                raise Problem('invalid_state', 'Only ambiguous submissions can be reconciled.')
            job.update(state='running', taskID=verified_task_id, message='Existing Cloud task recovered')
            self._save(db, principal.subject, state)

    def _advance_publication(self, principal, room):
        with self.db() as db:
            state = self._load(db, principal.subject, room)
            pub = next((p for p in state['publications'] if p['state'] in ('queued', 'publishing')), None)
            if not pub:
                return
            pub['state'] = 'publishing'
            revision = self._revision(state, pub['revisionID'])
            self._save(db, principal.subject, state)
        # Publisher contract REQUIRES idempotence, unlike experimental Cloud submit.
        # Failed/ambiguous publication leaves the old pointer and resumes this exact ID.
        try:
            url = self.publisher.publish(pub['id'], room, revision, pub['expected'])
        except Exception:
            return
        with self.db() as db:
            state = self._load(db, principal.subject, room)
            current = next(p for p in state['publications'] if p['id'] == pub['id'])
            if current['state'] == 'published':
                return
            if state['publishedRevisionID'] != pub['expected']:
                raise Problem('publication_conflict', 'Last working publication changed; reconcile before continuing.')
            current.update(state='published', url=url)
            state['publishedRevisionID'] = pub['revisionID']
            self._save(db, principal.subject, state)

    def published_document(self, principal, room):
        state = self.snapshot(principal, room)
        if not state['publishedRevisionID']:
            raise Problem('not_found', 'No approved publication yet.', 404)
        return self._revision(state, state['publishedRevisionID'])
