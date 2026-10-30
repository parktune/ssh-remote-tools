import argparse
import getpass
import json
import shutil
import subprocess

from .state import State
from .tailnet import NetworkError, Tailnet
from .transport import Client, PairService, PORT, TYPES


def run(args, *, root=None):
    network = Tailnet()
    if args.command == 'doctor':
        try:
            own = network.own()
            result = {'tailscale': 'running', 'device': own.get('HostName'),
                      'online_same_owner_peers': len(network.peers()), 'ssh_client': bool(shutil.which('ssh'))}
        except (NetworkError, OSError) as exc:
            result = {'tailscale': 'not_ready', 'action': str(exc)}
        print(json.dumps(result, ensure_ascii=False))
        return 0 if result['tailscale'] == 'running' else 1
    state = State(root)
    client = Client(network, state)
    if args.command == 'serve':
        service = PairService(network, state, allow_ssh=args.allow_ssh, port=args.port)
        with service.server() as server:
            print('Pairing code (one use, 5 minutes): ' + service.invitation.code, flush=True)
            print('Same-owner Tailscale peers only. Incoming messages are stored, never executed.', flush=True)
            print('SSH key enrollment: ' + ('ENABLED for this local account' if args.allow_ssh else 'disabled'), flush=True)
            try:
                server.serve_forever(poll_interval=0.25)
            except KeyboardInterrupt:
                pass
        return 0
    if args.command == 'connect':
        result = client.pair(getpass.getpass('Pairing code: '), port=args.port, return_port=args.return_port, ssh=args.ssh)
    elif args.command == 'peers':
        result = [{'name': peer['name'], 'node_id': peer['node_id'], 'ssh_granted': bool(peer.get('ssh'))}
                  for _, peer in state.items('out:')]
    elif args.command == 'ping':
        result = client.call(args.peer, '/v1/ping', {})
    elif args.command == 'message':
        result = client.send(args.peer, args.text, args.type, args.task)
    elif args.command == 'inbox':
        result = state.inbox()
    elif args.command == 'ack':
        state.ack(args.id)
        result = {'acknowledged': args.id}
    elif args.command == 'prune':
        state.prune()
        result = {'pruned': 'acknowledged messages'}
    elif args.command == 'revoke':
        paired = client.paired(args.peer)
        incoming = state.get('in:' + paired['node_id'], {})
        if incoming.get('ssh_granted'):
            from .ssh import revoke_key
            revoke_key(paired['node_id'])
        state.delete('in:' + paired['node_id'])
        state.delete('out:' + paired['node_id'])
        result = {'revoked_locally': paired['name'], 'remote_revocation_required': True}
    elif args.command == 'ssh':
        from .ssh import command
        paired = client.paired(args.peer)
        peer = network.node(paired['node_id'])
        return subprocess.call(command(state, paired, network.address(peer)))
    else:
        raise RuntimeError('Unknown command')
    print(json.dumps(result, ensure_ascii=False))
    return 0


def parser():
    top = argparse.ArgumentParser(description='Private pairing, messages and SSH over your own Tailscale network')
    sub = top.add_subparsers(dest='command', required=True)
    sub.add_parser('doctor')
    serve = sub.add_parser('serve')
    serve.add_argument('--allow-ssh', action='store_true', help='Explicitly permit public-key login to this local OS account')
    serve.add_argument('--port', type=int, default=PORT)
    connect = sub.add_parser('connect')
    connect.add_argument('--ssh', action='store_true', help='Request SSH access in addition to messages')
    connect.add_argument('--port', type=int, default=PORT)
    connect.add_argument('--return-port', type=int, default=PORT)
    sub.add_parser('peers')
    for name in ('ping', 'revoke', 'ssh'):
        sub.add_parser(name).add_argument('peer')
    send = sub.add_parser('message')
    send.add_argument('peer')
    send.add_argument('text')
    send.add_argument('--type', choices=sorted(TYPES), default='agent_message')
    send.add_argument('--task')
    sub.add_parser('inbox')
    sub.add_parser('ack').add_argument('id')
    sub.add_parser('prune')
    return top


def main():
    cli = parser()
    args = cli.parse_args()
    for name in ('port', 'return_port'):
        value = getattr(args, name, PORT)
        if not 1024 <= value <= 65535:
            cli.error('port must be between 1024 and 65535')
    try:
        raise SystemExit(run(args))
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as exc:
        cli.exit(1, 'srt: ' + str(exc) + '\n')


if __name__ == '__main__':
    main()
