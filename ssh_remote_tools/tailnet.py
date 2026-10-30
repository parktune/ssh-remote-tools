import ipaddress
import json
import os
import shutil
import subprocess
import threading
import time


class NetworkError(RuntimeError):
    pass


def tailscale_exe():
    path = shutil.which('tailscale')
    if not path and os.name == 'nt':
        candidate = os.path.join(os.environ.get('ProgramFiles', r'C:\Program Files'), 'Tailscale', 'tailscale.exe')
        if os.path.isfile(candidate):
            path = candidate
    if not path:
        raise NetworkError('Install Tailscale, log both devices into the same account, then retry.')
    return path


def private_ip(value):
    try:
        ip = ipaddress.ip_address(value)
        return ip.version == 4 and ip in ipaddress.ip_network('100.64.0.0/10')
    except ValueError:
        return False


class Tailnet:
    """Same-owner peers only. No tailnet-wide admin token or public-IP discovery."""
    def __init__(self, runner=None):
        self.runner = runner or self._run
        self.lock = threading.Lock()
        self.cached = None
        self.updated = 0

    @staticmethod
    def _run():
        result = subprocess.run([tailscale_exe(), 'status', '--json'], capture_output=True, text=True, timeout=10)
        if result.returncode:
            raise NetworkError('Tailscale status failed. Start Tailscale and sign in.')
        return json.loads(result.stdout)

    def snapshot(self, fresh=False):
        with self.lock:
            if fresh or self.cached is None or time.monotonic() - self.updated > 5:
                data = self.runner()
                if data.get('BackendState') != 'Running':
                    raise NetworkError('Tailscale is not Running. Sign in on this device first.')
                own = data.get('Self', {})
                if not own.get('ID') or not own.get('UserID'):
                    raise NetworkError('A user-owned Tailscale device is required; tagged/shared devices are not supported yet.')
                self.cached, self.updated = data, time.monotonic()
            return self.cached

    def own(self):
        node = self.snapshot()['Self']
        self.address(node)
        return node

    @staticmethod
    def address(node):
        for value in node.get('TailscaleIPs', []):
            if private_ip(value):
                return value
        raise NetworkError('No Tailscale IPv4 address is available')

    def peers(self):
        data = self.snapshot()
        owner = str(data['Self']['UserID'])
        return [p for p in data.get('Peer', {}).values()
                if p.get('ID') and str(p.get('UserID')) == owner
                and p.get('Online') and any(private_ip(a) for a in p.get('TailscaleIPs', []))]

    def caller(self, address):
        if not private_ip(address):
            raise NetworkError('Only authenticated same-owner Tailscale peers may connect')
        matches = [p for p in self.peers() if address in p.get('TailscaleIPs', [])]
        if len(matches) != 1:
            raise NetworkError('Caller is not an online peer owned by this Tailscale user')
        return matches[0]

    def node(self, node_id):
        matches = [p for p in self.peers() if p['ID'] == node_id]
        if len(matches) != 1:
            raise NetworkError('Paired device is offline or no longer belongs to this user')
        return matches[0]
