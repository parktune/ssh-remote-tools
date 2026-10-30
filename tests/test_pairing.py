import secrets
import unittest

from ssh_remote_tools.pairing import Invitation, new_code, normalize_code, proof


class PairingTests(unittest.TestCase):
    def test_one_use_and_mutual_proof(self):
        invite = Invitation('server')
        nonce = secrets.token_hex(24)
        hello = invite.hello(nonce)
        self.assertEqual(hello['proof'], proof(invite.code, 'server', 'server', invite.nonce, nonce))
        response = proof(invite.code, 'client', 'server', invite.nonce, nonce, 'client')
        self.assertEqual(invite.claim('client', nonce, response, lambda: 'granted'), 'granted')
        with self.assertRaises(RuntimeError):
            invite.claim('client', nonce, response, lambda: 'bad')

    def test_expiry_and_rate_limit(self):
        clock = [0]
        invite = Invitation('server', clock=lambda: clock[0])
        for _ in range(5):
            with self.assertRaises(PermissionError):
                invite.claim('client', 'nonce', 'bad', lambda: None)
        with self.assertRaises(RuntimeError):
            invite.claim('client', 'nonce', 'bad', lambda: None)
        clock[0] = 301
        with self.assertRaises(RuntimeError):
            invite.hello(secrets.token_hex(24))

    def test_short_codes_are_not_accepted(self):
        self.assertEqual(len(normalize_code(new_code())), 16)
        with self.assertRaises(ValueError):
            normalize_code('123456')
