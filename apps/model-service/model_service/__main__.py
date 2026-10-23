"""Explicit loopback-only synthetic harness. Not a production auth/server recipe."""
import argparse
import base64
import hmac
from pathlib import Path
from tempfile import TemporaryDirectory
from wsgiref.simple_server import make_server, WSGIRequestHandler
from .adapters import SyntheticPublisher, SyntheticRunner
from .contracts import Principal, digest
from .http import Application
from .service import Service


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--synthetic', action='store_true', required=True)
    parser.add_argument('--port', type=int, default=8787)
    args = parser.parse_args()
    # This password is intentionally public and useful only for synthetic localhost data.
    auth = 'Basic ' + base64.b64encode(b'demo:synthetic-only').decode()
    principal = Principal('synthetic-user', can_model=True, can_publish=True)
    with TemporaryDirectory(prefix='room-synthetic-') as directory:
        service = Service(Path(directory) / 'state.sqlite', SyntheticRunner(), SyntheticPublisher(), synthetic=True)
        service.register_scan(principal, 'demo', 'synthetic-scan', {'kind': 'synthetic', 'assetID': 'fixture', 'sha256': digest({'synthetic': True})})
        service.command(principal, 'demo', {'id': 'demo-model', 'kind': 'model', 'scanID': 'synthetic-scan'})
        service.advance(principal, 'demo'); state = service.advance(principal, 'demo')
        revision = state['revisions'][0]['id']
        service.command(principal, 'demo', {'id': 'demo-approve', 'kind': 'approve', 'revisionID': revision})
        service.command(principal, 'demo', {'id': 'demo-publish', 'kind': 'publish', 'revisionID': revision})
        service.advance(principal, 'demo')
        viewer = Path(__file__).resolve().parents[2] / 'protected-viewer' / 'dist'
        app = Application(service, lambda env: principal if hmac.compare_digest(env.get('HTTP_AUTHORIZATION', ''), auth) else None, viewer)
        class QuietHandler(WSGIRequestHandler):
            def log_message(self, *args):
                pass  # No URLs, headers or private identifiers in access logs.
        with make_server('127.0.0.1', args.port, app, handler_class=QuietHandler) as server:
            print(f'Synthetic ONLY: http://127.0.0.1:{args.port}/?room=demo — login demo / synthetic-only', flush=True)
            server.serve_forever()


if __name__ == '__main__':
    main()
