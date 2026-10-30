import concurrent.futures
import getpass
import hmac
import json
import re
import secrets
import socket
import threading
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .pairing import Invitation, normalize_code, proof, token_hash
from .tailnet import NetworkError, private_ip


PORT = 43123
MAX_BODY = 16384
TYPES = frozenset({'task_request', 'task_accepted', 'task_progress', 'task_completed', 'task_failed',
                   'file_transfer_request', 'file_transfer_completed', 'agent_message'})


def validate_message(message):
    if not isinstance(message, dict) or set(message) != {'id', 'task_id', 'type', 'text'}:
        raise ValueError('Expected id, task_id, type and text')
    for name in ('id', 'task_id'):
        if str(uuid.UUID(message[name])) != message[name]:
            raise ValueError('Canonical UUID required')
    if message['type'] not in TYPES or not isinstance(message['text'], str) or len(message['text']) > 8192:
        raise ValueError('Invalid message type or text')
    return message


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def request(address, port, path, body, token=None):
    if not private_ip(address) or not 1024 <= port <= 65535 or not path.startswith('/v1/'):
        raise NetworkError('Only direct Tailscale IPv4 endpoints are allowed')
    payload = json.dumps(body).encode()
    if len(payload) > MAX_BODY:
        raise ValueError('Message too large')
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request(f'http://{address}:{port}{path}', data=payload, headers=headers)
    # No HTTP_PROXY/HTTPS_PROXY, redirects, MagicDNS or external DNS lookups.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with opener.open(req, timeout=3) as response:
            data = response.read(MAX_BODY + 1)
            if len(data) > MAX_BODY:
                raise NetworkError('Response too large')
            return json.loads(data)
    except urllib.error.HTTPError as exc:
        raise NetworkError(f'Peer rejected request (HTTP {exc.code})') from None
    except (urllib.error.URLError, TimeoutError, ValueError):
        raise NetworkError('Peer is unreachable or returned an invalid response') from None


class PairService:
    def __init__(self, network, state, *, allow_ssh=False, port=PORT):
        self.network, self.state, self.port = network, state, port
        self.own = network.own()
        self.invitation = Invitation(self.own['ID'])
        self.ssh_info = None
        self.ssh_lock = threading.Lock()
        if allow_ssh:
            from .ssh import check_ssh_user, host_key
            check_ssh_user()
            self.ssh_info = {'user': getpass.getuser(), 'host_key': host_key()}

    def dispatch(self, caller, path, body, token=None):
        caller_id = caller['ID']
        if not isinstance(body, dict):
            raise ValueError('JSON object required')
        if path == '/v1/hello':
            return self.invitation.hello(body.get('nonce', ''))
        if path == '/v1/pair':
            nonce = body.get('nonce', '')
            reverse = body.get('return_token', '')
            return_port = body.get('return_port', PORT)
            if not isinstance(nonce, str) or not re.fullmatch('[a-f0-9]{48}', nonce):
                raise ValueError('Invalid challenge')
            if not isinstance(reverse, str) or not re.fullmatch('[A-Za-z0-9_-]{43}', reverse):
                raise ValueError('Invalid return credential')
            if not isinstance(return_port, int) or not 1024 <= return_port <= 65535:
                raise ValueError('Invalid return port')

            def grant():
                ssh = None
                if body.get('ssh_key'):
                    if not self.ssh_info:
                        raise PermissionError('SSH authorization was not enabled by this host')
                    from .ssh import authorize
                    with self.ssh_lock:
                        authorize(body['ssh_key'], caller_id)
                    ssh = self.ssh_info
                credential = secrets.token_urlsafe(32)
                self.state.set_many({
                    'in:' + caller_id: {'hash': token_hash(credential), 'name': caller.get('HostName', 'peer'),
                                        'ssh_granted': bool(ssh) or self.state.get('in:' + caller_id, {}).get('ssh_granted', False)},
                    'out:' + caller_id: {'node_id': caller_id, 'name': caller.get('HostName', 'peer'),
                                         'token': reverse, 'port': return_port,
                                         'ssh': self.state.get('out:' + caller_id, {}).get('ssh')},
                })
                return {'node_id': self.own['ID'], 'token': credential, 'ssh': ssh, 'protocol': 1}
            return self.invitation.claim(caller_id, nonce, body.get('proof', ''), grant)
        record = self.state.get('in:' + caller_id)
        if not record or not isinstance(token, str) or not hmac.compare_digest(record['hash'], token_hash(token)):
            raise PermissionError('Peer is not paired')
        if path == '/v1/ping':
            return {'ok': True, 'protocol': 1}
        if path == '/v1/message':
            return self.state.deliver(caller_id, validate_message(body))
        raise ValueError('Unknown endpoint')

    def server(self):
        service = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.0'

            def log_message(self, *args):
                pass  # Never log pairing artifacts, tokens or remote message text.

            def setup(self):
                super().setup()
                self.connection.settimeout(5)

            def do_POST(self):
                try:
                    if self.headers.get('Origin') or self.headers.get('Transfer-Encoding'):
                        raise PermissionError('Browser origins and chunked requests are not allowed')
                    if self.headers.get('Content-Type') != 'application/json':
                        raise ValueError('JSON required')
                    size = int(self.headers.get('Content-Length', '0'))
                    if not 0 < size <= MAX_BODY:
                        raise ValueError('Invalid content length')
                    caller = service.network.caller(self.client_address[0])
                    raw = self.rfile.read(size)
                    if len(raw) != size:
                        raise ValueError('Incomplete request')
                    body = json.loads(raw)
                    auth = self.headers.get('Authorization', '')
                    token = auth[7:] if auth.startswith('Bearer ') and len(auth) < 160 else None
                    result = service.dispatch(caller, self.path, body, token)
                    self.reply(200, result)
                except (PermissionError, NetworkError):
                    self.reply(403, {'error': 'forbidden'})
                except (ValueError, TypeError, KeyError):
                    self.reply(400, {'error': 'invalid_request'})
                except RuntimeError:
                    self.reply(409, {'error': 'unavailable_or_conflict'})
                except (OSError, socket.timeout):
                    self.close_connection = True

            def reply(self, code, value):
                data = json.dumps(value).encode()
                self.send_response(code)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data)))
                self.send_header('Cache-Control', 'no-store')
                self.end_headers()
                self.wfile.write(data)

        class Server(ThreadingHTTPServer):
            daemon_threads = True
            allow_reuse_address = True
            request_queue_size = 32

            def __init__(self, *args):
                self.slots = threading.BoundedSemaphore(32)
                super().__init__(*args)

            def process_request(self, request, address):
                if not self.slots.acquire(blocking=False):
                    self.shutdown_request(request)
                    return
                try:
                    super().process_request(request, address)
                except BaseException:
                    self.slots.release()
                    raise

            def process_request_thread(self, request, address):
                try:
                    super().process_request_thread(request, address)
                finally:
                    self.slots.release()

        return Server((self.network.address(self.own), self.port), Handler)


class Client:
    def __init__(self, network, state, transport=request):
        self.network, self.state, self.transport = network, state, transport

    def pair(self, code, *, port=PORT, return_port=PORT, ssh=False):
        code = normalize_code(code)
        nonce = secrets.token_hex(24)
        peers = self.network.peers()
        if len(peers) > 256:
            raise NetworkError('Discovery is limited to 256 same-owner online peers')

        def discover(peer):
            try:
                data = self.transport(self.network.address(peer), port, '/v1/hello', {'nonce': nonce})
                if data.get('node_id') != peer['ID'] or data.get('protocol') != 1:
                    return None
                expected = proof(code, 'server', data['node_id'], data['nonce'], nonce)
                if hmac.compare_digest(expected, data['proof']):
                    return peer, data
            except (NetworkError, ValueError, KeyError, TypeError):
                pass
            return None

        with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
            found = [result for result in pool.map(discover, peers) if result is not None]
        if len(found) != 1:
            raise NetworkError('No unique matching host found. Check the code, expiry, both serve processes and tailnet policy.')
        peer, hello = found[0]
        own = self.network.own()
        reverse = secrets.token_urlsafe(32)
        body = {'nonce': nonce, 'proof': proof(code, 'client', peer['ID'], hello['nonce'], nonce, own['ID']),
                'return_token': reverse, 'return_port': return_port}
        if ssh:
            from .ssh import keypair
            body['ssh_key'] = keypair(self.state)
        response = self.transport(self.network.address(peer), port, '/v1/pair', body)
        if response.get('node_id') != peer['ID'] or not re.fullmatch('[A-Za-z0-9_-]{43}', response.get('token', '')):
            raise NetworkError('Invalid pairing response')
        outgoing = {'node_id': peer['ID'], 'name': peer.get('HostName', 'peer'), 'port': port,
                    'token': response['token'], 'ssh': response.get('ssh') or self.state.get('out:' + peer['ID'], {}).get('ssh')}
        self.state.set_many({'out:' + peer['ID']: outgoing,
                             'in:' + peer['ID']: {'hash': token_hash(reverse), 'name': peer.get('HostName', 'peer'),
                                                   'ssh_granted': self.state.get('in:' + peer['ID'], {}).get('ssh_granted', False)}})
        return {'peer': peer.get('HostName', 'peer'), 'node_id': peer['ID'], 'ssh_granted': bool(response.get('ssh'))}

    def paired(self, name):
        matches = [value for _, value in self.state.items('out:') if name in (value['node_id'], value['name'])]
        if len(matches) != 1:
            raise NetworkError('Choose one unambiguous paired name or node ID from peers')
        return matches[0]

    def call(self, name, path, body):
        paired = self.paired(name)
        peer = self.network.node(paired['node_id'])
        return self.transport(self.network.address(peer), paired['port'], path, body, paired['token'])

    def send(self, name, text, kind='agent_message', task_id=None):
        message = {'id': str(uuid.uuid4()), 'task_id': task_id or str(uuid.uuid4()), 'type': kind, 'text': text}
        validate_message(message)
        receipt = self.call(name, '/v1/message', message)
        return {**receipt, 'task_id': message['task_id']}
