"""80-bit one-use pairing over an already authenticated Tailscale network.

This is not a PAKE or a replacement for Tailscale. Discovery proves possession of
an 80-bit random secret, never sending it to candidate peers. No six-digit codes.
"""
import base64
import hashlib
import hmac
import json
import re
import secrets
import threading
import time


def new_code():
    return '-'.join(re.findall('.{4}', base64.b32encode(secrets.token_bytes(10)).decode()))


def normalize_code(value):
    result = value.upper().replace('-', '').replace(' ', '')
    if not re.fullmatch('[A-Z2-7]{16}', result):
        raise ValueError('Pairing code must contain 16 base32 characters')
    return result


def proof(code, role, *parts):
    key = normalize_code(code).encode()
    message = json.dumps([role, *parts], separators=(',', ':')).encode()
    return hmac.new(key, message, hashlib.sha256).hexdigest()


def token_hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


class Invitation:
    def __init__(self, node_id, lifetime=300, clock=time.monotonic):
        self.code = new_code()
        self.nonce = secrets.token_hex(24)
        self.node_id = node_id
        self.clock = clock
        self.expires = clock() + lifetime
        self.used = False
        self.failures = {}
        self.lock = threading.Lock()

    def hello(self, client_nonce):
        if not re.fullmatch('[a-f0-9]{48}', client_nonce):
            raise ValueError('Invalid challenge')
        with self.lock:
            if self.used or self.clock() >= self.expires:
                raise RuntimeError('Pairing window closed; restart serve to generate a new code')
            return {'protocol': 1, 'node_id': self.node_id, 'nonce': self.nonce,
                    'proof': proof(self.code, 'server', self.node_id, self.nonce, client_nonce)}

    def claim(self, caller_id, client_nonce, response, grant):
        with self.lock:
            if self.used or self.clock() >= self.expires:
                raise RuntimeError('Pairing window closed')
            if sum(self.failures.values()) >= 30 or self.failures.get(caller_id, 0) >= 5:
                raise RuntimeError('Too many pairing attempts; restart serve for a new code')
            expected = proof(self.code, 'client', self.node_id, self.nonce, client_nonce, caller_id)
            if not hmac.compare_digest(expected, str(response)):
                self.failures[caller_id] = self.failures.get(caller_id, 0) + 1
                raise PermissionError('Pairing proof rejected')
            result = grant()
            self.used = True
            return result
