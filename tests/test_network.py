import json
import unittest

from ssh_remote_tools.tailnet import NetworkError, Tailnet, private_ip


class NetworkTests(unittest.TestCase):
    def status(self):
        return {'BackendState': 'Running', 'Self': {'ID': 'self', 'UserID': 1, 'TailscaleIPs': ['100.64.0.1']},
                'Peer': {'ok': {'ID': 'ok', 'UserID': 1, 'Online': True, 'TailscaleIPs': ['100.64.0.2']},
                         'other': {'ID': 'other', 'UserID': 2, 'Online': True, 'TailscaleIPs': ['100.64.0.3']},
                         'off': {'ID': 'off', 'UserID': 1, 'Online': False, 'TailscaleIPs': ['100.64.0.4']}}}

    def test_only_online_same_owner_peers(self):
        net = Tailnet(self.status)
        self.assertEqual([p['ID'] for p in net.peers()], ['ok'])
        self.assertEqual(net.caller('100.64.0.2')['ID'], 'ok')
        for ip in ('100.64.0.3', '100.64.0.4', '8.8.8.8', '127.0.0.1'):
            with self.assertRaises(NetworkError):
                net.caller(ip)

    def test_not_all_100_addresses_are_tailscale(self):
        self.assertTrue(private_ip('100.127.255.254'))
        for ip in ('100.1.2.3', '100.128.0.1', '192.168.1.1', 'example.com', '::1'):
            self.assertFalse(private_ip(ip))

    def test_logout_and_tagged_nodes_fail_closed(self):
        for data in ({'BackendState': 'NeedsLogin'}, {'BackendState': 'Running', 'Self': {'ID': 'tagged'}}):
            with self.assertRaises(NetworkError):
                Tailnet(lambda: data).own()
