import json
from pathlib import Path
import socket
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from codec import fit, save_model, sha256
from live_bridge_server import Controller, handle_connection, PROTOCOL
from monitor_signals import SIGNALS
from test_live_bridge import waveform
from test_monitor_capture import message


class ExternalBridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.model = Path(cls.temp.name)/'model.pt'
        model, _ = fit()
        save_model(model, cls.model)
        cls.digest = sha256(cls.model)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.temp_output = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_output.cleanup)
        self.output = Path(self.temp_output.name)
        self.controller = Controller(self.model, self.digest)
        self.addCleanup(self.controller.close)

    def init(self):
        return self.controller.dispatch(dict(command='init', model_sha256=self.digest,
                                             out_dir=str(self.output), max_age_seconds=5))

    def test_hello_and_init_do_not_open_monitor_or_gateway(self):
        hello = self.controller.dispatch(dict(command='hello'))
        self.assertEqual(hello['protocol'], PROTOCOL)
        self.assertFalse(hello['monitor_started'])
        self.init()
        self.assertIsNone(self.controller.bridge.server)
        self.assertIsNone(self.controller.bridge.gateway)
        with self.assertRaises(ValueError):
            self.controller.dispatch(dict(command='next'))
        with self.assertRaises(ValueError):
            self.init()

    def test_model_mismatch_fails_before_initialization(self):
        with self.assertRaises(ValueError):
            self.controller.dispatch(dict(command='init', model_sha256='0'*64,
                                          out_dir=str(self.output), max_age_seconds=5))
        self.assertIsNone(self.controller.bridge)
        self.assertFalse((self.output/'events.jsonl').exists())

    def test_multi_signal_ipc_negotiation_and_singleton_matlab_encoding(self):
        hello = self.controller.dispatch(dict(command='hello'))
        self.assertEqual(hello['supported_signals'], list(SIGNALS))
        result = self.controller.dispatch(dict(command='init', model_sha256=self.digest,
                                              out_dir=str(self.output), max_age_seconds=5,
                                              signals=list(SIGNALS)))
        self.assertEqual(result['signals'], list(SIGNALS))
        self.assertIsNone(self.controller.bridge.server)
        with tempfile.TemporaryDirectory() as other:
            controller = Controller(self.model, self.digest)
            try:
                result = controller.dispatch(dict(command='init', model_sha256=self.digest,
                                                   out_dir=other, max_age_seconds=5,
                                                   signals='pulse_rate'))
                self.assertEqual(result['signals'], ['pulse_rate'])
            finally:
                controller.close()

    def test_dispatch_rx_roundtrip_with_synthetic_phy_no_network(self):
        self.init()
        bridge = self.controller.bridge
        sent = []
        bridge._send = lambda envelope, received: sent.append(envelope)
        with patch.object(bridge, 'start') as start:
            self.controller.dispatch(dict(command='start', host='192.0.2.1'))
            start.assert_called_once_with('192.0.2.1', 2222, '127.0.0.1', 4455)
        bridge.feed_message(message(value='70'))
        request = self.controller.dispatch(dict(command='next'))
        rx = json.loads(waveform(request['tx_bits']))
        result = self.controller.dispatch(dict(command='receive', rx_aligned=rx))
        self.assertTrue(result['codec_ok'])
        self.assertTrue(result['gateway_write_ok'])
        self.assertEqual(sent[0]['payload']['variables'][0]['value'], '70')
        self.assertEqual(self.controller.dispatch(dict(command='stats'))['attempted'], 1)

    def connection(self):
        client, server = socket.socketpair()
        client.settimeout(2)
        server.settimeout(2)
        errors = []

        def worker():
            with server:
                try:
                    handle_connection(server, self.controller, 'a'*64)
                except ValueError as exc:
                    errors.append(type(exc).__name__)
                finally:
                    self.controller.close()

        thread = threading.Thread(target=worker)
        thread.start()
        self.addCleanup(thread.join, 2)
        self.addCleanup(client.close)
        return client, thread, errors

    def test_persistent_json_wire_fragmentation_and_clean_close(self):
        client, thread, errors = self.connection()
        with client.makefile('rwb') as wire:
            request = json.dumps(dict(command='hello', token='a'*64)).encode() + b'\n'
            client.sendall(request[:10])
            client.sendall(request[10:])
            hello = json.loads(wire.readline())
            self.assertEqual(hello['data']['protocol'], PROTOCOL)
            # Same socket/process: no launch per command.
            wire.write((json.dumps(dict(command='close', token='a'*64)) + '\n').encode())
            wire.flush()
            self.assertTrue(json.loads(wire.readline())['data']['closed'])
        thread.join(2)
        self.assertFalse(thread.is_alive())
        self.assertEqual(errors, [])

    def test_wrong_token_and_nonfinite_json_are_rejected(self):
        for payload in (
            json.dumps(dict(command='hello', token='b'*64)).encode() + b'\n',
            b'{"command":"hello","token":"' + b'a'*64 + b'","value":NaN}\n',
        ):
            client, thread, errors = self.connection()
            client.sendall(payload)
            self.assertEqual(client.recv(100), b'')
            thread.join(2)
            self.assertFalse(thread.is_alive())
            self.assertEqual(errors, ['ValueError'])
        self.assertIsNone(self.controller.bridge)

    def test_unknown_command_fails_closed_without_echoing_request(self):
        client, thread, errors = self.connection()
        request = dict(command='SYNTHETIC_PRIVATE_TEXT', token='a'*64)
        client.sendall((json.dumps(request)+'\n').encode())
        with client.makefile('rb') as wire:
            response = wire.readline()
            self.assertFalse(json.loads(response)['ok'])
            self.assertNotIn(b'SYNTHETIC_PRIVATE_TEXT', response)
            self.assertEqual(wire.readline(), b'')
        thread.join(2)
        self.assertFalse(thread.is_alive())
        self.assertEqual(errors, [])


if __name__ == '__main__':
    unittest.main()
