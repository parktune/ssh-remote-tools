import http.client
import json
import tempfile
import threading
import unittest
import uuid
from pathlib import Path

from ssh_remote_tools.state import State
from ssh_remote_tools.tailnet import NetworkError
from ssh_remote_tools.transport import Client, PairService, request


class FakeNetwork:
    def __init__(self, own, peer):
        self.self_node, self.peer = own, peer

    def own(self):
        return self.self_node

    def peers(self):
        return [self.peer]

    def address(self, node):
        return '127.0.0.1' if node['ID'] == self.self_node['ID'] else node['TailscaleIPs'][0]

    def node(self, node_id):
        if node_id != self.peer['ID']:
            raise NetworkError('Unknown peer')
        return self.peer

    def caller(self, address):
        return self.peer


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        a = {'ID': 'node-a', 'HostName': 'alpha', 'TailscaleIPs': ['100.64.0.1']}
        b = {'ID': 'node-b', 'HostName': 'beta', 'TailscaleIPs': ['100.64.0.2']}
        self.na, self.nb = FakeNetwork(a, b), FakeNetwork(b, a)
        self.sa = State(Path(self.temp.name, 'a'))
        self.sb = State(Path(self.temp.name, 'b'))
        self.services = [PairService(self.na, self.sa, port=0), PairService(self.nb, self.sb, port=0)]
        self.servers = [s.server() for s in self.services]
        self.threads = [threading.Thread(target=s.serve_forever, kwargs={'poll_interval': .01}) for s in self.servers]
        for t in self.threads:
            t.start()
        self.ca = Client(self.na, self.sa, self.transport)
        self.cb = Client(self.nb, self.sb, self.transport)

    def tearDown(self):
        for server in self.servers:
            server.shutdown()
            server.server_close()
        for thread in self.threads:
            thread.join()
        self.temp.cleanup()

    def transport(self, address, port, path, body, token=None):
        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=3)
        headers = {'Content-Type': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        try:
            connection.request('POST', path, json.dumps(body), headers)
            response = connection.getresponse()
            data = json.loads(response.read())
            if response.status != 200:
                raise NetworkError('Rejected ' + str(response.status))
            return data
        finally:
            connection.close()

    def pair(self):
        return self.cb.pair(self.services[0].invitation.code,
                            port=self.servers[0].server_port, return_port=self.servers[1].server_port)

    def test_single_code_pairs_both_directions(self):
        self.pair()
        self.assertTrue(self.cb.call('alpha', '/v1/ping', {})['ok'])
        self.assertTrue(self.ca.call('beta', '/v1/ping', {})['ok'])
        sent = self.cb.send('alpha', 'hello', 'task_request')
        message = self.sa.inbox()[0]
        self.assertEqual(message['sender'], 'node-b')
        self.assertEqual(message['text'], 'hello')
        self.ca.send('beta', 'hello received', 'task_completed', sent['task_id'])
        self.assertEqual(self.sb.inbox()[0]['task_id'], sent['task_id'])
        self.assertEqual(self.sb.inbox()[0]['text'], 'hello received')

    def test_wrong_code_does_not_pair(self):
        from ssh_remote_tools.pairing import new_code
        with self.assertRaises(NetworkError):
            self.cb.pair(new_code(), port=self.servers[0].server_port)
        self.assertEqual(self.sa.items('in:'), [])

    def test_credential_bound_to_peer_and_revocable(self):
        self.pair()
        self.sa.delete('in:node-b')
        with self.assertRaises(NetworkError):
            self.cb.call('alpha', '/v1/ping', {})

    def test_message_retry_is_idempotent_and_collision_rejected(self):
        self.pair()
        msg = {'id': str(uuid.uuid4()), 'task_id': str(uuid.uuid4()), 'type': 'agent_message', 'text': 'same'}
        self.assertFalse(self.cb.call('alpha', '/v1/message', msg)['duplicate'])
        self.assertTrue(self.cb.call('alpha', '/v1/message', msg)['duplicate'])
        msg['text'] = 'changed'
        with self.assertRaises(NetworkError):
            self.cb.call('alpha', '/v1/message', msg)

    def test_default_service_rejects_ssh_enrollment(self):
        # A valid proof still cannot authorize SSH unless the host opted in.
        from ssh_remote_tools.pairing import proof
        import secrets
        invite = self.services[0].invitation
        nonce = secrets.token_hex(24)
        body = {'nonce': nonce, 'proof': proof(invite.code, 'client', 'node-a', invite.nonce, nonce, 'node-b'),
                'return_token': secrets.token_urlsafe(32), 'return_port': 43123, 'ssh_key': 'anything'}
        with self.assertRaises(PermissionError):
            self.services[0].dispatch(self.nb.own(), '/v1/pair', body)
        self.assertFalse(invite.used)

    def test_arbitrary_public_destination_is_rejected(self):
        with self.assertRaises(NetworkError):
            request('8.8.8.8', 43123, '/v1/ping', {})

    def test_origin_is_rejected(self):
        connection = http.client.HTTPConnection('127.0.0.1', self.servers[0].server_port)
        try:
            connection.request('POST', '/v1/hello', '{}', {'Content-Type': 'application/json', 'Origin': 'https://example.com'})
            self.assertEqual(connection.getresponse().status, 403)
        finally:
            connection.close()
