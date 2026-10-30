"""Opt-in OpenSSH key authorization and strict host-key pinning."""
import base64
import hashlib
import os
import re
import shutil
import struct
import subprocess
from pathlib import Path


MARKER = 'ssh-remote-tools-v2:'


def public_key(text):
    parts = text.strip().split()
    if len(parts) < 2 or parts[0] != 'ssh-ed25519' or '\n' in text.strip() or '\r' in text:
        raise ValueError('A single OpenSSH ed25519 public key is required')
    try:
        raw = base64.b64decode(parts[1], validate=True)
    except ValueError:
        raise ValueError('Invalid public key encoding') from None
    expected = struct.pack('>I', 11) + b'ssh-ed25519' + struct.pack('>I', 32)
    if len(raw) != len(expected) + 32 or not raw.startswith(expected):
        raise ValueError('Invalid ed25519 key')
    return parts[0] + ' ' + parts[1]


def host_key():
    path = (Path(os.environ.get('ProgramData', r'C:\ProgramData')) / 'ssh/ssh_host_ed25519_key.pub'
            if os.name == 'nt' else Path('/etc/ssh/ssh_host_ed25519_key.pub'))
    if not path.exists():
        raise RuntimeError('Install and start OpenSSH Server before using --allow-ssh')
    return public_key(path.read_text())


def keypair(state):
    path = state.root / 'id_ed25519'
    if not path.exists():
        executable = shutil.which('ssh-keygen')
        if not executable:
            raise RuntimeError('Install OpenSSH Client first')
        subprocess.run([executable, '-q', '-t', 'ed25519', '-N', '', '-f', str(path)],
                       check=True, capture_output=True, timeout=30)
        path.chmod(0o600)
    if path.is_symlink():
        raise RuntimeError('SSH private key must not be a symlink')
    return public_key(path.with_suffix('.pub').read_text())


def check_ssh_user():
    if os.name == 'nt':
        groups = subprocess.run(['whoami', '/groups', '/fo', 'csv', '/nh'],
                                capture_output=True, text=True, check=True, timeout=10).stdout
        if 'S-1-5-32-544' in groups:
            raise RuntimeError('Automatic SSH enrollment on Windows requires a non-administrator account. See docs/setup.md.')


def authorize(key, node_id, home=None):
    check_ssh_user()
    key = public_key(key)
    directory = Path(home or Path.home()) / '.ssh'
    if directory.is_symlink():
        raise RuntimeError('.ssh must not be a symlink')
    directory.mkdir(mode=0o700, exist_ok=True)
    directory.chmod(0o700)
    path = directory / 'authorized_keys'
    if path.is_symlink():
        raise RuntimeError('authorized_keys must not be a symlink')
    label = MARKER + hashlib.sha256(node_id.encode()).hexdigest()[:20]
    line = 'no-agent-forwarding,no-X11-forwarding,no-port-forwarding ' + key + ' ' + label
    flags = os.O_RDWR | os.O_CREAT | getattr(os, 'O_NOFOLLOW', 0)
    fd = os.open(path, flags, 0o600)
    with os.fdopen(fd, 'r+', encoding='utf-8') as file:
        old = file.read()
        if label not in old:
            file.seek(0, 2)
            file.write(('\n' if old and not old.endswith('\n') else '') + line + '\n')
            file.flush()
            os.fsync(file.fileno())
    path.chmod(0o600)
    return label


def revoke_key(node_id, home=None):
    path = Path(home or Path.home()) / '.ssh/authorized_keys'
    if not path.exists():
        return
    if path.is_symlink():
        raise RuntimeError('authorized_keys must not be a symlink')
    label = MARKER + hashlib.sha256(node_id.encode()).hexdigest()[:20]
    with path.open('r+', encoding='utf-8') as file:
        lines = file.readlines()
        file.seek(0)
        file.writelines(line for line in lines if not line.rstrip().endswith(' ' + label))
        file.truncate()


def command(state, paired, address):
    from .tailnet import private_ip
    if not private_ip(address) or not paired.get('ssh'):
        raise RuntimeError('Peer did not grant SSH access')
    keypair(state)
    identity = hashlib.sha256(paired['node_id'].encode()).hexdigest()[:24]
    alias = 'srt-' + identity
    path = state.root / (identity + '.known_hosts')
    content = alias + ' ' + public_key(paired['ssh']['host_key']) + '\n'
    if path.is_symlink():
        raise RuntimeError('Pinned host key must not be a symlink')
    if path.exists() and path.read_text() != content:
        raise RuntimeError('SSH host key changed; revoke and explicitly pair again')
    path.write_text(content)
    path.chmod(0o600)
    return ['ssh', '-F', 'NUL' if os.name == 'nt' else '/dev/null',
            '-o', 'StrictHostKeyChecking=yes', '-o', 'IdentitiesOnly=yes',
            '-o', 'UserKnownHostsFile=' + str(path), '-o', 'HostKeyAlias=' + alias,
            '-i', str(state.root / 'id_ed25519'), '-l', paired['ssh']['user'], '--', address]
