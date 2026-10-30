import base64
import os
import shutil
import struct
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from ssh_remote_tools.ssh import authorize, command, public_key, revoke_key
from ssh_remote_tools.state import State


KEY = 'ssh-ed25519 ' + base64.b64encode(struct.pack('>I', 11) + b'ssh-ed25519' + struct.pack('>I', 32) + bytes(range(32))).decode()


class SshTests(unittest.TestCase):
    def test_key_validation_blocks_injection(self):
        self.assertEqual(public_key(KEY + ' comment'), KEY)
        for bad in ('ssh-rsa AAA', KEY+'\ncommand="bad"', 'ssh-ed25519 AAAA'):
            with self.assertRaises(ValueError):
                public_key(bad)

    def test_authorize_and_revoke_preserve_unrelated_keys(self):
        with tempfile.TemporaryDirectory() as root, patch('ssh_remote_tools.ssh.check_ssh_user'):
            folder = Path(root, '.ssh')
            folder.mkdir()
            path = folder / 'authorized_keys'
            path.write_text('unrelated-existing-key\n')
            authorize(KEY, 'peer', home=root)
            self.assertIn('no-port-forwarding', path.read_text())
            self.assertIn(KEY, path.read_text())
            authorize(KEY, 'peer', home=root)
            self.assertEqual(path.read_text().count(KEY), 1)
            revoke_key('peer', home=root)
            self.assertEqual(path.read_text(), 'unrelated-existing-key\n')

    @unittest.skipUnless(shutil.which('ssh-keygen'), 'OpenSSH client required')
    def test_host_key_is_pinned_and_changed_key_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            state = State(root)
            paired = {'node_id': 'peer', 'ssh': {'user': 'user', 'host_key': KEY}}
            args = command(state, paired, '100.64.0.2')
            self.assertIn('StrictHostKeyChecking=yes', args)
            self.assertEqual(args[-1], '100.64.0.2')
            paired['ssh']['host_key'] = 'ssh-ed25519 ' + base64.b64encode(struct.pack('>I', 11) + b'ssh-ed25519' + struct.pack('>I', 32) + b'x'*32).decode()
            with self.assertRaisesRegex(RuntimeError, 'changed'):
                command(state, paired, '100.64.0.2')
