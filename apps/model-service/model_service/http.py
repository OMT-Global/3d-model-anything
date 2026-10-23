"""WSGI API + private viewer. Deployment supplies authentication; default denies all."""
import json
import mimetypes
from pathlib import Path
from .adapters import GatedRunner, GatedPublisher
from .contracts import Principal, Problem, canonical


class Application:
    def __init__(self, service, authenticate=lambda environ: None, viewer=None):
        self.service, self.authenticate = service, authenticate
        self.viewer = Path(viewer).resolve() if viewer else None

    def __call__(self, environ, start_response):
        headers = [('Cache-Control', 'no-store'), ('X-Content-Type-Options', 'nosniff'),
                   ('Referrer-Policy', 'no-referrer'), ('Cross-Origin-Resource-Policy', 'same-origin'),
                   ('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")]
        try:
            principal = self.authenticate(environ)
            if not isinstance(principal, Principal):
                raise Problem('unauthorized', 'Sign in to the private viewer.', 401)
            method, path = environ['REQUEST_METHOD'], environ.get('PATH_INFO', '/')
            # No CORS. Block cross-origin browser mutations, including cookie-auth deployments.
            if method not in ('GET', 'HEAD'):
                origin = environ.get('HTTP_ORIGIN')
                expected = environ.get('wsgi.url_scheme', 'https') + '://' + environ.get('HTTP_HOST', '')
                if (origin and origin != expected) or environ.get('HTTP_SEC_FETCH_SITE') == 'cross-site':
                    raise Problem('forbidden', 'Cross-origin requests are not allowed.', 403)
            parts = path.strip('/').split('/')
            if path == '/v1/capabilities' and method == 'GET':
                result = {'mode': 'synthetic' if self.service.synthetic else 'integration',
                          'model': principal.can_model, 'publish': principal.can_publish,
                          'cloudAdapterConfigured': not isinstance(self.service.runner, GatedRunner),
                          'siteAdapterConfigured': not isinstance(self.service.publisher, GatedPublisher)}
            elif len(parts) >= 3 and parts[:2] == ['v1', 'rooms']:
                room = parts[2]
                if method == 'GET' and len(parts) == 3:
                    result = self.service.snapshot(principal, room)
                elif method == 'GET' and parts[3:] == ['published']:
                    result = self.service.published_document(principal, room)
                elif method == 'POST' and parts[3:] == ['commands']:
                    result = self.service.command(principal, room, self._body(environ))
                elif method == 'POST' and parts[3:] == ['advance']:
                    self._body(environ)
                    result = self.service.advance(principal, room)
                else:
                    raise Problem('not_found', 'Route unavailable.', 404)
            elif method == 'GET' and self.viewer:
                target = (self.viewer / (path.lstrip('/') or 'index.html')).resolve()
                if not target.is_relative_to(self.viewer) or not target.is_file():
                    raise Problem('not_found', 'Asset unavailable.', 404)
                # Authentication applies to HTML, JS and every future texture/geometry route.
                payload = target.read_bytes()
                content_type = mimetypes.guess_type(target)[0] or 'application/octet-stream'
                start_response('200 OK', headers + [('Content-Type', content_type)])
                return [payload]
            else:
                raise Problem('not_found', 'Route unavailable.', 404)
            status, payload = 200, canonical(result).encode()
        except Problem as error:
            status, payload = error.status, canonical({'code': error.code, 'message': str(error)}).encode()
        except (ValueError, TypeError, KeyError):
            status, payload = 400, b'{"code":"invalid_request","message":"Invalid request body."}'
        except Exception:
            status, payload = 500, b'{"code":"unavailable","message":"Service unavailable. Retry the same request ID."}'
        from http import HTTPStatus
        if status == 401:
            headers.append(('WWW-Authenticate', 'Basic realm="Synthetic preview"'))
        start_response(f'{status} {HTTPStatus(status).phrase}', headers + [('Content-Type', 'application/json')])
        return [payload]

    @staticmethod
    def _body(environ):
        if environ.get('CONTENT_TYPE', '').split(';')[0] != 'application/json':
            raise Problem('content_type', 'Expected application/json.', 415)
        length = int(environ.get('CONTENT_LENGTH') or 0)
        if not 0 < length <= 1_000_000:
            raise Problem('body_size', 'Expected a JSON body up to 1 MB.', 413)
        return json.loads(environ['wsgi.input'].read(length))
