from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from monitor_capture import parse_rates
from monitor_signals import SIGNALS, compact_observation, parse_compact, parse_observations


def signal_message(signal, value='70', unit=None, status='F'):
    spec = SIGNALS[signal]
    return (f'MSH|^~\\&|SYNTHETIC||||20261117000000||ORU^R01|1|P|2.3\r'
            f'OBX|1|NM|{spec["code"]}^{spec["name"]}^MDC|{spec["sub_id"]}|{value}|'
            f'0^{unit or spec["unit_code"]}^MDC|||||{status}\r').encode()


def combined(*messages):
    return messages[0] + b''.join(m[m.index(b'OBX|'):] for m in messages[1:])


class MonitorSignalTests(unittest.TestCase):
    def test_three_distinct_fields_and_compact_frames(self):
        body = combined(signal_message('heart_rate', '73'),
                        signal_message('oxygen_saturation', '97'),
                        signal_message('pulse_rate', '74'))
        records = parse_observations(body)
        self.assertEqual([r['signal'] for r in records],
                         ['heart_rate', 'oxygen_saturation', 'pulse_rate'])
        self.assertEqual([compact_observation(r) for r in records],
                         [b'!#MDHR0073', b'!#MDSP0097', b'!#MDPR0074'])
        for record in records:
            self.assertEqual(parse_compact(compact_observation(record), record['signal']),
                             record['value'])
        # Historical capture CLI stays rate-only with its value_bpm contract.
        rates = parse_rates(body)
        self.assertEqual([r['value_bpm'] for r in rates], [73, 74])

    def test_spo2_units_range_and_no_rounding(self):
        for value in ('1', '97', '100'):
            self.assertTrue(parse_observations(signal_message('oxygen_saturation', value))[0]['eligible'])
        for value in ('0', '-100', '101', '9999', 'NaN', 'Infinity', '97.5', '--'):
            row = parse_observations(signal_message('oxygen_saturation', value))[0]
            self.assertFalse(row['eligible'], value)
            self.assertIsNone(row['value'])
        row = parse_observations(signal_message('oxygen_saturation', '97',
                                               unit='MDC_DIM_BEAT_PER_MIN'))[0]
        self.assertEqual(row['reason'], 'unexpected_units')
        row = parse_observations(signal_message('heart_rate', '73', unit='MDC_DIM_PERCENT'))[0]
        self.assertEqual(row['reason'], 'unexpected_units')

    def test_duplicate_signal_does_not_invalidate_other_signals(self):
        body = combined(signal_message('oxygen_saturation', '97'),
                        signal_message('oxygen_saturation', '98'),
                        signal_message('pulse_rate', '74'))
        records = parse_observations(body)
        self.assertFalse(records[0]['eligible'])
        self.assertFalse(records[1]['eligible'])
        self.assertTrue(records[2]['eligible'])

    def test_decoder_cannot_substitute_pr_for_hr_or_accept_invalid_spo2(self):
        for source, signal in ((b'!#MDPR0073', 'heart_rate'),
                               (b'!#MDHR0073', 'pulse_rate'),
                               (b'!#MDSP0101', 'oxygen_saturation'),
                               (b'!#MDSP0000', 'oxygen_saturation')):
            with self.assertRaises(ValueError):
                parse_compact(source, signal)


if __name__ == '__main__':
    unittest.main()
