"""Explicit loopback IPC for older MATLAB releases, using the existing Python venv.

One authenticated controller, one persistent model, bounded newline-delimited JSON.
No pyenv, subprocess per reading, or instrument access. Importing opens no sockets.
"""
import argparse
import hmac
import json
from pathlib import Path
import secrets
import socket

from codec import sha256
from live_bridge import LiveBridge

MAX_LINE = 1024 * 1024
PROTOCOL = 'vlc_neural_ipc_v1'


def reject_constant(value):
    raise ValueError('Non-finite JSON number')


class Controller:
    def __init__(self, model_path, model_hash):
        self.model_path = model_path
        self.model_hash = model_hash
        self.bridge = None
        self.started = False

    def dispatch(self, request):
        command = request['command']
        if command == 'hello':
            return dict(protocol=PROTOCOL, model_sha256=self.model_hash, monitor_started=self.started)
        if command == 'init':
            if self.bridge is not None or request['model_sha256'] != self.model_hash:
                raise ValueError('Wrong model or already initialized')
            out = Path(request['out_dir']).resolve()
            if not out.is_dir():
                raise ValueError('MATLAB must create the output directory first')
            self.bridge = LiveBridge(self.model_path, self.model_hash,
                                     out/'events.jsonl', request['max_age_seconds'])
            return dict(initialized=True)
        if command == 'close':
            self.close()
            return dict(closed=True)
        if self.bridge is None:
            raise ValueError('Initialize the bridge first')
        if command == 'start':
            if self.started:
                raise ValueError('Already started')
            self.bridge.start(request['host'], 2222, '127.0.0.1', 4455)
            self.started = True
            return dict(started=True)
        if command == 'stats':
            return json.loads(self.bridge.stats_json())
        if not self.started:
            raise ValueError('Monitor listener has not been started')
        if command == 'next':
            return json.loads(self.bridge.next_json())
        if command == 'receive':
            return json.loads(self.bridge.receive_json(json.dumps(request['rx_aligned'], allow_nan=False)))
        if command == 'reject':
            self.bridge.reject()
            return dict(rejected=True)
        raise ValueError('Unknown command')

    def close(self):
        if self.bridge is not None:
            self.bridge.close()


def handle_connection(connection, controller, token):
    """All commands carry the per-process token. Invalid sessions terminate."""
    with connection.makefile('rwb') as wire:
        while True:
            line = wire.readline(MAX_LINE + 1)
            if not line:
                return
            if len(line) > MAX_LINE or not line.endswith(b'\n'):
                raise ValueError('Oversized or incomplete IPC line')
            request = json.loads(line, parse_constant=reject_constant)
            if (not isinstance(request, dict) or not isinstance(request.get('token'), str)
                    or not hmac.compare_digest(request['token'], token)):
                raise ValueError('Invalid IPC session token')
            command = request.get('command')
            try:
                data = controller.dispatch(request)
                response = dict(ok=True, data=data)
            except (ValueError, KeyError, TypeError, OSError, RuntimeError):
                # Do not echo arbitrary request contents, paths, or telemetry.
                response = dict(ok=False, error='bridge_command_failed')
            wire.write((json.dumps(response, allow_nan=False) + '\n').encode('utf-8'))
            wire.flush()
            if command == 'close' or not response['ok']:
                return


def serve(model_path, model_hash, port):
    if sha256(model_path) != model_hash:
        raise ValueError('Frozen model hash mismatch')
    controller = Controller(model_path, model_hash)
    token = secrets.token_hex(32)
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
            # Control plane is loopback ONLY; monitor uses its separate interface.
            server.bind(('127.0.0.1', port))
            server.listen(1)
            server.settimeout(120)
            print(f'IPC ready: 127.0.0.1:{server.getsockname()[1]}', flush=True)
            print(f'Control token (local use only): {token}', flush=True)
            print('Monitor listener and VLC are NOT active. Waiting for MATLAB.', flush=True)
            connection, _ = server.accept()
            with connection:
                connection.settimeout(120)
                handle_connection(connection, controller, token)
    finally:
        controller.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serve', action='store_true', required=True)
    parser.add_argument('--model', required=True)
    parser.add_argument('--model-sha256', required=True)
    parser.add_argument('--port', type=int, default=47651)
    args = parser.parse_args()
    if not 1 <= args.port <= 65535 or args.port in (2222, 4444, 4455):
        parser.error('Select a separate control port')
    serve(args.model, args.model_sha256, args.port)


if __name__ == '__main__':
    main()
