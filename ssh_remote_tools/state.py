import json
from contextlib import contextmanager
import os
import sqlite3
import subprocess
from pathlib import Path


def default_root():
    if os.name == 'nt':
        return Path(os.environ['LOCALAPPDATA']) / 'ssh-remote-tools-v2'
    return Path(os.environ.get('XDG_STATE_HOME', Path.home() / '.local/state')) / 'ssh-remote-tools'


def protect_directory(path):
    path = Path(path)
    if path.is_symlink():
        raise RuntimeError('State directories must not be symlinks')
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if os.name == 'nt':
        result = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command',
                                 '[System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value'],
                                capture_output=True, text=True, timeout=10, check=True)
        sid = result.stdout.strip()
        if not sid.startswith('S-1-') or any(c not in 'S-0123456789' for c in sid):
            raise RuntimeError('Cannot determine Windows state owner')
        subprocess.run(['icacls', str(path), '/inheritance:r', '/grant:r',
                        f'*{sid}:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F'],
                       capture_output=True, timeout=10, check=True)
    else:
        path.chmod(0o700)


class State:
    def __init__(self, root=None):
        self.root = Path(root) if root is not None else default_root()
        protect_directory(self.root)
        self.path = self.root / 'state.sqlite3'
        if self.path.is_symlink():
            raise RuntimeError('State database must not be a symlink')
        with self.db() as db:
            db.execute('CREATE TABLE IF NOT EXISTS records (key TEXT PRIMARY KEY, value TEXT NOT NULL)')
            db.execute('''CREATE TABLE IF NOT EXISTS inbox
                (id TEXT PRIMARY KEY, sender TEXT NOT NULL, body TEXT NOT NULL, created REAL NOT NULL, ack INTEGER NOT NULL DEFAULT 0)''')
        self.path.chmod(0o600)

    @contextmanager
    def db(self):
        connection = sqlite3.connect(self.path, timeout=10)
        try:
            with connection:
                yield connection
        finally:
            connection.close()

    def get(self, key, default=None):
        with self.db() as db:
            row = db.execute('SELECT value FROM records WHERE key=?', (key,)).fetchone()
        return json.loads(row[0]) if row else default

    def set(self, key, value):
        with self.db() as db:
            db.execute('INSERT OR REPLACE INTO records VALUES (?,?)', (key, json.dumps(value)))

    def set_many(self, values):
        with self.db() as db:
            db.executemany('INSERT OR REPLACE INTO records VALUES (?,?)',
                           [(k, json.dumps(v)) for k, v in values.items()])

    def delete(self, key):
        with self.db() as db:
            db.execute('DELETE FROM records WHERE key=?', (key,))

    def items(self, prefix):
        with self.db() as db:
            rows = db.execute('SELECT key,value FROM records WHERE key LIKE ?', (prefix+'%',)).fetchall()
        return [(k, json.loads(v)) for k, v in rows]

    def deliver(self, sender, message):
        import time
        body = json.dumps(message, sort_keys=True)
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            old = db.execute('SELECT sender,body FROM inbox WHERE id=?', (message['id'],)).fetchone()
            if old:
                if old != (sender, body):
                    raise RuntimeError('Message ID collision')
                return {'id': message['id'], 'duplicate': True}
            count = db.execute('SELECT COUNT(*) FROM inbox').fetchone()[0]
            if count >= 10000:
                raise RuntimeError('Inbox capacity reached; acknowledge and prune local messages')
            db.execute('INSERT INTO inbox(id,sender,body,created) VALUES (?,?,?,?)',
                       (message['id'], sender, body, time.time()))
        return {'id': message['id'], 'duplicate': False}

    def inbox(self, limit=50):
        with self.db() as db:
            rows = db.execute('SELECT sender,body FROM inbox WHERE ack=0 ORDER BY created LIMIT ?', (limit,)).fetchall()
        return [{'sender': sender, **json.loads(body)} for sender, body in rows]

    def ack(self, message_id):
        with self.db() as db:
            db.execute('UPDATE inbox SET ack=1 WHERE id=?', (message_id,))

    def prune(self):
        with self.db() as db:
            db.execute('DELETE FROM inbox WHERE ack=1')
