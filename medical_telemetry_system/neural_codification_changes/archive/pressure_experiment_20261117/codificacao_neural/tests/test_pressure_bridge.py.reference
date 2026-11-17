import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from codec import fit, save_model, sha256
from live_bridge import LiveBridge
from monitor_signals import PRESSURE_SIGNALS, SIGNALS, compact_observation, parse_observations
from test_live_bridge import waveform
from test_monitor_signals import combined, signal_message


def pressure_message(systolic='120', diastolic='80'):
    return combined(signal_message('systolic_pressure', systolic),
                    signal_message('diastolic_pressure', diastolic))


def timestamped(body, stamp):
    lines = body.split(b'\r')
    for index, line in enumerate(lines):
        if line.startswith(b'OBX|'):
            fields = line.split(b'|')
            fields += [b''] * (15-len(fields))
            fields[14] = stamp
            lines[index] = b'|'.join(fields)
    return b'\r'.join(lines)


class PressureBridgeTests(unittest.TestCase):
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
        self.bridge = LiveBridge(self.path, self.digest, Path(self.output.name)/'events.jsonl',
                                 max_age=5, signals=list(SIGNALS))
        self.addCleanup(self.bridge.close)
        self.sent = []
        self.bridge._send = lambda envelope, received: self.sent.append(envelope)

    def next(self):
        return json.loads(self.bridge.next_json())

    def receive(self, request):
        return json.loads(self.bridge.receive_json(waveform(request['tx_bits'])))

    def test_sys_dia_identifiers_units_and_representation(self):
        rows = parse_observations(pressure_message())
        self.assertEqual([r['unit'] for r in rows], ['mmHg', 'mmHg'])
        self.assertEqual([compact_observation(r) for r in rows],
                         [b'!#MDBS0120', b'!#MDBD0080'])
        row = parse_observations(signal_message('systolic_pressure', '120',
                                               unit='MDC_DIM_PERCENT'))[0]
        self.assertEqual(row['reason'], 'unexpected_units')
        for value in ('0', '-100', '120.5', '10000'):
            self.assertFalse(parse_observations(signal_message('systolic_pressure', value))[0]['eligible'])

    def test_pair_published_together_only_after_two_rx_fragments(self):
        self.bridge.feed_message(pressure_message())
        first = self.next()
        self.assertEqual(first['signal'], 'systolic_pressure')
        self.assertEqual((first['fragment_index'], first['fragment_total']), (0, 2))
        self.assertEqual(len(first['tx_bits']), 392)
        result = self.receive(first)
        self.assertTrue(result['codec_ok'])
        self.assertFalse(result['gateway_write_ok'])
        self.assertFalse(result['message_complete'])
        self.assertEqual(result['reason'], 'awaiting_pressure_pair')
        self.assertEqual(self.sent, [])
        second = self.next()
        self.assertEqual(second['message_id'], first['message_id'])
        self.assertEqual(second['signal'], 'diastolic_pressure')
        self.assertEqual((second['fragment_index'], second['fragment_total']), (1, 2))
        self.assertEqual(len(second['tx_bits']), 392)
        result = self.receive(second)
        self.assertTrue(result['gateway_write_ok'])
        self.assertTrue(result['message_complete'])
        variables = self.sent[0]['payload']['variables']
        numeric = {v['name']: (v['value'], v['unit']) for v in variables if v['value'] != '-?-'}
        self.assertEqual(numeric, {'Systolic Pressure': ('120', 'mmHg'),
                                   'Diastolic Pressure': ('80', 'mmHg')})
        stats = json.loads(self.bridge.stats_json())
        self.assertEqual(stats['attempted'], 2)
        self.assertEqual(stats['codec_ok'], 2)
        self.assertEqual(stats['gateway_write_ok'], 1)
        for signal in PRESSURE_SIGNALS:
            self.assertEqual(stats['signals'][signal]['gateway_write_ok'], 1)

    def test_next_measurement_never_mixed_with_inflight_pressure(self):
        self.bridge.feed_message(pressure_message('120', '80'))
        self.receive(self.next())
        self.bridge.feed_message(pressure_message('130', '90'))
        self.receive(self.next())
        first = {v['name']: v['value'] for v in self.sent[0]['payload']['variables']
                 if v['value'] != '-?-'}
        self.assertEqual(first, {'Systolic Pressure': '120', 'Diastolic Pressure': '80'})
        self.receive(self.next())
        self.receive(self.next())
        second = {v['name']: v['value'] for v in self.sent[1]['payload']['variables']
                  if v['value'] != '-?-'}
        self.assertEqual(second, {'Systolic Pressure': '130', 'Diastolic Pressure': '90'})

    def test_failed_first_or_second_fragment_never_delivers_half_pair(self):
        for corrupt_index in (0, 1):
            self.bridge.feed_message(pressure_message())
            for index in range(corrupt_index+1):
                request = self.next()
                if index == corrupt_index:
                    request['tx_bits'][300] ^= 1
                result = self.receive(request)
            self.assertFalse(result['gateway_write_ok'])
            self.assertEqual(self.next(), {})
        self.assertEqual(self.sent, [])

    def test_missing_or_invalid_half_is_not_paired_across_envelopes(self):
        self.bridge.feed_message(signal_message('systolic_pressure', '120'))
        self.assertEqual(self.next(), {})
        self.bridge.feed_message(signal_message('diastolic_pressure', '80'))
        self.assertEqual(self.next(), {})
        self.bridge.feed_message(pressure_message('120', '-100'))
        self.assertEqual(self.next(), {})
        self.bridge.feed_message(signal_message('pulse_rate', '74'))
        self.assertTrue(self.receive(self.next())['gateway_write_ok'])
        self.assertFalse(any(v['name'] in ('Systolic Pressure', 'Diastolic Pressure')
                             for v in self.sent[-1]['payload']['variables']))

    def test_pressure_timestamps_must_match_when_present(self):
        systolic = timestamped(signal_message('systolic_pressure', '120'), b'20261117120000')
        diastolic = timestamped(signal_message('diastolic_pressure', '80'), b'20261117120100')
        self.bridge.feed_message(combined(systolic, diastolic))
        self.assertEqual(self.next(), {})
        self.assertEqual(self.bridge.signal_counts[
            'systolic_pressure']['rejected_inconsistent_pressure_time'], 1)
        diastolic = timestamped(signal_message('diastolic_pressure', '80'), b'20261117120000')
        self.bridge.feed_message(combined(systolic, diastolic))
        self.assertEqual(self.next()['fragment_total'], 2)
        self.bridge.reject()
        self.bridge.close()
        self.assertNotIn('20261117120000', self.bridge.audit_path.read_text())

    def test_pair_expiry_or_invalidation_between_fragments_discards_staged_rx(self):
        now = time.monotonic()
        with patch('live_bridge.time.monotonic', return_value=now):
            self.bridge.feed_message(pressure_message())
            self.receive(self.next())
        with patch('live_bridge.time.monotonic', return_value=now+6):
            self.assertEqual(self.next(), {})
        self.assertEqual(self.sent, [])
        self.bridge.feed_message(pressure_message())
        self.receive(self.next())
        self.bridge.feed_message(pressure_message('-100', '-100'))
        self.assertEqual(self.next(), {})
        self.assertEqual(self.sent, [])

    def test_all_five_fields_use_four_logical_units_and_five_packets(self):
        body = combined(signal_message('heart_rate', '73'),
                        signal_message('oxygen_saturation', '97'),
                        signal_message('pulse_rate', '74'), pressure_message())
        self.bridge.feed_message(body)
        self.assertEqual(len(self.bridge.latest), 4)
        for signal in SIGNALS:
            request = self.next()
            self.assertEqual(request['signal'], signal)
            self.receive(request)
        self.assertEqual(len(self.sent), 4)
        self.assertEqual(self.bridge.counts['attempted'], 5)
        self.assertEqual(self.bridge.counts['logical_prepared'], 4)

    def test_half_pressure_configuration_rejected(self):
        for signal in PRESSURE_SIGNALS:
            with self.assertRaisesRegex(ValueError, 'together'):
                LiveBridge(self.path, self.digest, Path(self.output.name)/'bad.jsonl',
                           signals=['pulse_rate', signal])
        self.assertFalse((Path(self.output.name)/'bad.jsonl').exists())


if __name__ == '__main__':
    unittest.main()
