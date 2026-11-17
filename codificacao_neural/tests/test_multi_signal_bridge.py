import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from codec import encode, fit, save_model, sha256
from live_bridge import LiveBridge
from monitor_signals import VITAL_SIGNALS
from packets import pack_packet
from test_live_bridge import waveform
from test_monitor_signals import combined, signal_message


class MultiSignalBridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.model_path = Path(cls.temp.name)/'model.pt'
        model, _ = fit()
        save_model(model, cls.model_path)
        cls.digest = sha256(cls.model_path)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.output = tempfile.TemporaryDirectory()
        self.addCleanup(self.output.cleanup)
        self.bridge = LiveBridge(self.model_path, self.digest, Path(self.output.name)/'events.jsonl',
                                 max_age=5, signals=list(VITAL_SIGNALS))
        self.addCleanup(self.bridge.close)
        self.sent = []
        self.bridge._send = lambda envelope, received: self.sent.append(envelope)

    def receive(self, request):
        return json.loads(self.bridge.receive_json(waveform(request['tx_bits'])))

    def test_all_three_roundtrip_without_model_or_phy_changes(self):
        self.bridge.feed_message(combined(signal_message('heart_rate', '73'),
                                          signal_message('oxygen_saturation', '97'),
                                          signal_message('pulse_rate', '74')))
        numeric = {}
        for signal in VITAL_SIGNALS:
            req = json.loads(self.bridge.next_json())
            self.assertEqual(req['signal'], signal)
            self.assertEqual(len(req['tx_bits']), 392)
            result = self.receive(req)
            self.assertTrue(result['source_exact_match'])
            self.assertTrue(result['gateway_write_ok'])
            self.assertEqual(result['signal'], signal)
            self.assertEqual(result['bit_errors'], 0)
            for variable in self.sent[-1]['payload']['variables']:
                if variable['value'] != '-?-':
                    numeric[variable['name']] = (variable['value'], variable['unit'])
        self.assertEqual(numeric, {'Ecg Heart Rate': ('73', '1/min'),
                                   'Puls Oxim Sat O2': ('97', '%'),
                                   'Puls Oxim Puls Rate': ('74', '1/min')})
        stats = json.loads(self.bridge.stats_json())
        self.assertEqual(stats['source_accepted'], 3)
        for signal in VITAL_SIGNALS:
            self.assertEqual(stats['signals'][signal]['gateway_write_ok'], 1)
        self.assertEqual(self.bridge.next_json(), '{}')

    def test_round_robin_and_latest_per_variable(self):
        self.bridge.feed_message(combined(*(signal_message(s) for s in VITAL_SIGNALS)))
        req = json.loads(self.bridge.next_json())
        self.assertEqual(req['signal'], 'heart_rate')
        self.receive(req)
        for value in ('71', '72', '73'):
            self.bridge.feed_message(signal_message('heart_rate', value))
        for signal in ('oxygen_saturation', 'pulse_rate', 'heart_rate'):
            req = json.loads(self.bridge.next_json())
            self.assertEqual(req['signal'], signal)
            self.receive(req)
        self.assertEqual(self.sent[-1]['payload']['variables'][0]['value'], '73')
        self.assertEqual(self.bridge.signal_counts['heart_rate']['queue_dropped'], 2)
        self.assertEqual(self.bridge.signal_counts['pulse_rate']['queue_dropped'], 0)

    def test_invalid_ecg_does_not_cancel_spo2_or_pr(self):
        self.bridge.feed_message(combined(signal_message('heart_rate', '-100'),
                                          signal_message('oxygen_saturation', '97'),
                                          signal_message('pulse_rate', '74')))
        for signal in ('oxygen_saturation', 'pulse_rate'):
            req = json.loads(self.bridge.next_json())
            self.assertEqual(req['signal'], signal)
            result = self.receive(req)
            self.assertTrue(result['gateway_write_ok'])
        self.assertEqual(self.bridge.next_json(), '{}')
        self.assertEqual(self.bridge.signal_counts['heart_rate']['source_rejected'], 1)
        self.assertEqual(self.bridge.signal_counts['pulse_rate']['source_rejected'], 0)
        for env in self.sent:
            hr = [v for v in env['payload']['variables'] if v['name'] == 'Ecg Heart Rate']
            self.assertEqual(hr[0]['value'], '-?-')

    def test_inflight_invalidation_is_per_signal(self):
        self.bridge.feed_message(signal_message('pulse_rate', '74'))
        req = json.loads(self.bridge.next_json())
        self.bridge.feed_message(signal_message('heart_rate', '-100'))
        self.assertTrue(self.receive(req)['gateway_write_ok'])
        self.bridge.feed_message(signal_message('oxygen_saturation', '97'))
        req = json.loads(self.bridge.next_json())
        self.bridge.feed_message(signal_message('oxygen_saturation', '-100'))
        self.assertFalse(self.receive(req)['gateway_write_ok'])
        self.assertEqual(self.bridge.signal_counts['oxygen_saturation']['invalidated'], 1)

    def test_old_or_invalid_card_cleared_without_replaying_numeric_cache(self):
        now = time.monotonic()
        with patch('live_bridge.time.monotonic', return_value=now):
            self.bridge.feed_message(signal_message('heart_rate', '73'))
            self.receive(json.loads(self.bridge.next_json()))
        with patch('live_bridge.time.monotonic', return_value=now+1):
            self.bridge.feed_message(signal_message('pulse_rate', '74'))
            result = self.receive(json.loads(self.bridge.next_json()))
            self.assertNotIn('heart_rate', result['cleared_signals'])
            self.assertFalse(any(v['name'] == 'Ecg Heart Rate'
                                 for v in self.sent[-1]['payload']['variables']))
        with patch('live_bridge.time.monotonic', return_value=now+6):
            self.bridge.feed_message(signal_message('oxygen_saturation', '97'))
            result = self.receive(json.loads(self.bridge.next_json()))
            self.assertIn('heart_rate', result['cleared_signals'])
            hr = [v for v in self.sent[-1]['payload']['variables'] if v['name'] == 'Ecg Heart Rate']
            self.assertEqual(hr[0]['value'], '-?-')
            self.assertEqual(sum(v['value'] != '-?-'
                                 for v in self.sent[-1]['payload']['variables']), 1)

    def test_expired_queue_does_not_block_another_fresh_variable(self):
        now = time.monotonic()
        with patch('live_bridge.time.monotonic', return_value=now):
            self.bridge.feed_message(signal_message('heart_rate', '73'))
        with patch('live_bridge.time.monotonic', return_value=now+6):
            self.bridge.feed_message(signal_message('pulse_rate', '74'))
            req = json.loads(self.bridge.next_json())
            self.assertEqual(req['signal'], 'pulse_rate')
            self.assertTrue(self.receive(req)['gateway_write_ok'])
        self.assertEqual(self.bridge.signal_counts['heart_rate']['stale_dropped'], 1)

    def test_valid_crc_of_wrong_signal_cannot_route_to_another_card(self):
        self.bridge.feed_message(signal_message('heart_rate', '73'))
        req = json.loads(self.bridge.next_json())
        source = b'!#MDPR0073'
        packet = pack_packet(encode(self.bridge.model, source), source, self.bridge.identity,
                             req['message_id'], 0, 1)
        bits = np.unpackbits(np.frombuffer(packet, dtype=np.uint8))
        result = json.loads(self.bridge.receive_json(waveform(bits)))
        self.assertFalse(result['codec_ok'])
        self.assertEqual(self.sent, [])

    def test_invalid_signal_selections_rejected_without_outputs(self):
        for signals in ([], ['pulse_rate', 'pulse_rate'], ['temperature'], 'pulse_rate'):
            with self.assertRaises(ValueError):
                LiveBridge(self.model_path, self.digest, Path(self.output.name)/'invalid.jsonl',
                           signals=signals)
        self.assertFalse((Path(self.output.name)/'invalid.jsonl').exists())


if __name__ == '__main__':
    unittest.main()
