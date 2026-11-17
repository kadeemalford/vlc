import json
from pathlib import Path
import socket
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from codec import fit, save_model, sha256
from live_bridge import LiveBridge
from packets import pack_packet
from test_monitor_capture import message


def waveform(bits):
    levels = np.asarray(bits, dtype=float)*2-1
    return json.dumps(np.concatenate([np.r_[np.repeat(x, 5), np.repeat(-x, 5)]
                                     for x in levels]).tolist())


class LiveBridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.path = Path(cls.temp.name)/'model.pt'
        model, _ = fit()
        save_model(model, cls.path)
        cls.digest = sha256(cls.path)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.output = tempfile.TemporaryDirectory()
        self.addCleanup(self.output.cleanup)
        self.bridge = LiveBridge(self.path, self.digest, Path(self.output.name)/'events.jsonl', 5)
        self.addCleanup(self.bridge.close)
        self.sent = []
        self.bridge._send = lambda envelope, received: self.sent.append(envelope)

    def request(self, value='70'):
        self.bridge.feed_message(message(value=value))
        return json.loads(self.bridge.next_json())

    def test_no_sockets_on_construction_hash_and_exclusive_output(self):
        self.assertIsNone(self.bridge.server)
        self.assertIsNone(self.bridge.gateway)
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            LiveBridge(self.path, '0'*64, Path(self.output.name)/'wrong.jsonl')
        with self.assertRaises(FileExistsError):
            LiveBridge(self.path, self.digest, self.bridge.audit_path)

    def test_valid_rx_preserves_legacy_contract_and_ber(self):
        request = self.request()
        result = json.loads(self.bridge.receive_json(waveform(request['tx_bits'])))
        self.assertTrue(result['codec_ok'])
        self.assertTrue(result['gateway_write_ok'])
        self.assertFalse(result['panel_delivery_confirmed'])
        self.assertEqual(result['bit_errors'], 0)
        self.assertEqual(self.sent, [{
            'source': 'monitor_message', 'payload': {
                'type': 'Monitor Measurements',
                'variables': [{'name': 'Puls Oxim Puls Rate', 'value': '70', 'unit': '1/min'}],
                'alarms': []}}])

    def test_corrupt_and_invalid_rx_never_delivered(self):
        for bad in ('[]', '[NaN]', '{}', 'not json'):
            self.request()
            result = json.loads(self.bridge.receive_json(bad))
            self.assertFalse(result['codec_ok'])
        request = self.request()
        request['tx_bits'][300] ^= 1
        self.assertFalse(json.loads(self.bridge.receive_json(
            waveform(request['tx_bits'])))['codec_ok'])
        self.assertEqual(self.sent, [])

    def test_wrong_model_message_and_source_crc_block_gateway(self):
        from codec import encode
        for identity, mid, source, latent in (
            (b'12345678', 1, b'!#MDPR0070', None),
            (self.bridge.identity, 999, b'!#MDPR0070', None),
            (self.bridge.identity, None, b'!#MDPR0070', b'\0'*20),
        ):
            req = self.request()
            packet = pack_packet(latent if latent is not None else encode(self.bridge.model, source),
                                 source, identity, req['message_id'] if mid is None else mid, 0, 1)
            bits = np.unpackbits(np.frombuffer(packet, dtype=np.uint8))
            result = json.loads(self.bridge.receive_json(waveform(bits)))
            self.assertFalse(result['codec_ok'])
        self.assertEqual(self.sent, [])

    def test_latest_only_and_invalid_source_clears_queue(self):
        self.bridge.feed_message(message(value='70'))
        self.bridge.feed_message(message(value='71'))
        req = json.loads(self.bridge.next_json())
        self.bridge.receive_json(waveform(req['tx_bits']))
        self.assertEqual(self.sent[0]['payload']['variables'][0]['value'], '71')
        self.assertEqual(self.bridge.counts['queue_dropped'], 1)
        self.bridge.feed_message(message(value='72'))
        self.bridge.feed_message(message(value='-100'))
        self.assertEqual(self.bridge.next_json(), '{}')
        self.bridge.feed_message(message(signal='heart_rate'))
        self.assertEqual(self.bridge.next_json(), '{}')

    def test_stale_queue_and_inflight_are_not_delivered(self):
        now = time.monotonic()
        self.bridge.feed_message(message())
        with patch('live_bridge.time.monotonic', return_value=now+10):
            self.assertEqual(self.bridge.next_json(), '{}')
        req = self.request()
        with patch('live_bridge.time.monotonic', return_value=now+10):
            result = json.loads(self.bridge.receive_json(waveform(req['tx_bits'])))
        self.assertEqual(result['reason'], 'stale')
        self.assertEqual(self.sent, [])

    def test_invalid_signal_during_phy_invalidates_pending(self):
        req = self.request()
        self.bridge.feed_message(message(value='-100'))
        result = json.loads(self.bridge.receive_json(waveform(req['tx_bits'])))
        self.assertTrue(result['codec_ok'])
        self.assertFalse(result['gateway_write_ok'])
        self.assertEqual(result['source_invalid_reason'],
                         'outside_representation_range_or_missing')
        self.assertEqual(self.bridge.counts[
            'pr_rejected_outside_representation_range_or_missing'], 1)
        self.assertEqual(self.sent, [])

    def test_message_without_pr_preserves_queued_observation(self):
        self.bridge.feed_message(message(value='70'))
        self.bridge.feed_message(message(signal='heart_rate', value='80'))
        req = json.loads(self.bridge.next_json())
        result = json.loads(self.bridge.receive_json(waveform(req['tx_bits'])))
        self.assertTrue(result['gateway_write_ok'])
        self.assertEqual(self.sent[0]['payload']['variables'][0]['value'], '70')
        self.assertEqual(self.bridge.counts['messages_without_pr'], 1)
        self.assertEqual(self.bridge.counts['source_rejected'], 0)
        self.assertEqual(self.bridge.counts['queue_dropped'], 0)

    def test_message_without_pr_does_not_invalidate_inflight(self):
        req = self.request()
        self.bridge.feed_message(message(signal='heart_rate', value='80'))
        result = json.loads(self.bridge.receive_json(waveform(req['tx_bits'])))
        self.assertTrue(result['codec_ok'])
        self.assertTrue(result['gateway_write_ok'])
        self.assertEqual(self.bridge.counts['invalidated'], 0)

    def test_message_without_pr_does_not_refresh_observation_age(self):
        received = time.monotonic()
        self.bridge.feed_message(message(value='70'))
        with patch('live_bridge.time.monotonic', return_value=received+10):
            self.bridge.feed_message(message(signal='heart_rate', value='80'))
            self.assertEqual(self.bridge.next_json(), '{}')
        self.assertEqual(self.bridge.counts['stale_dropped'], 1)
        self.assertEqual(self.sent, [])

    def test_duplicate_pr_is_still_rejected_and_classified(self):
        req = self.request()
        body = message(value='70')
        body += body[body.index(b'OBX|'):]
        self.bridge.feed_message(body)
        result = json.loads(self.bridge.receive_json(waveform(req['tx_bits'])))
        self.assertFalse(result['gateway_write_ok'])
        self.assertEqual(result['source_invalid_reason'], 'ambiguous_duplicate_signal')
        self.assertEqual(self.bridge.counts['pr_rejected_ambiguous_duplicate_signal'], 1)
        self.assertEqual(self.sent, [])

    def test_no_retry_no_tx_fallback_and_single_inflight(self):
        req = self.request()
        with self.assertRaises(ValueError):
            self.bridge.next_json()
        with patch.object(self.bridge, '_send', side_effect=OSError):
            result = json.loads(self.bridge.receive_json(waveform(req['tx_bits'])))
        self.assertTrue(result['codec_ok'])
        self.assertFalse(result['gateway_write_ok'])
        self.assertEqual(self.bridge.next_json(), '{}')
        with self.assertRaises(ValueError):
            self.bridge.receive_json(waveform(req['tx_bits']))
        self.request()
        self.bridge.reject()
        self.assertIsNone(self.bridge.pending)
        self.assertEqual(self.sent, [])

    def test_no_identifiers_or_raw_hl7_in_audit(self):
        self.request()
        self.bridge.reject()
        self.bridge.close()
        log = self.bridge.audit_path.read_text()
        for forbidden in ('PID', 'SYNTHETIC_PRIVATE_ID', 'MSH|'):
            self.assertNotIn(forbidden, log)
        for line in log.splitlines():
            json.loads(line)

    def test_fragmented_monitor_socket_and_listener_cleanup(self):
        received = threading.Event()
        original = self.bridge.feed_message

        def consume(body):
            original(body)
            received.set()

        self.bridge.feed_message = consume
        self.bridge.start('127.0.0.1', 0)
        address = self.bridge.server.getsockname()
        with socket.create_connection(address, timeout=1) as client:
            client.sendall(b'\x0b' + message(value='73')[:20])
            client.sendall(message(value='73')[20:] + b'\x1c\r')
            self.assertTrue(received.wait(2))
        req = json.loads(self.bridge.next_json())
        self.bridge.receive_json(waveform(req['tx_bits']))
        self.assertEqual(self.sent[0]['payload']['variables'][0]['value'], '73')
        self.bridge.close()
        self.assertFalse(self.bridge.worker.is_alive())

    def test_gateway_wire_is_ndjson_and_expiry_blocks_send(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
            server.bind(('127.0.0.1', 0))
            server.listen(1)
            server.settimeout(1)
            self.bridge.gateway_address = server.getsockname()
            del self.bridge._send  # Exercise real TCP write, not the test sink.
            req = self.request()
            result = json.loads(self.bridge.receive_json(waveform(req['tx_bits'])))
            self.assertTrue(result['gateway_write_ok'])
            connection, _ = server.accept()
            with connection:
                connection.settimeout(1)
                wire = connection.recv(4096)
                self.assertTrue(wire.endswith(b'\n'))
                payload = json.loads(wire)
                self.assertEqual(payload['source'], 'monitor_message')
                self.assertIsInstance(payload['payload']['variables'], list)
                self.assertEqual(payload['payload']['alarms'], [])
            with self.assertRaises(TimeoutError):
                self.bridge._send(payload, time.monotonic()-10)


if __name__ == '__main__':
    unittest.main()
