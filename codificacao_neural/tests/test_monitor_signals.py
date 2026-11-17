import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from monitor_capture import SessionWriter, parse_rates
from monitor_signals import (SIGNALS, compact_observation, parse_compact,
                             parse_observations, pressure_diagnostics)


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

    def test_pressure_diagnostic_identifies_unrecognized_mapping_without_values(self):
        systolic = signal_message('systolic_pressure', '123456789').replace(b'150301^', b'999999^')
        body = combined(systolic, signal_message('diastolic_pressure', '80'))
        report = pressure_diagnostics(body)
        self.assertEqual(report['recognized_counts'],
                         {'systolic_pressure': 0, 'diastolic_pressure': 1})
        field = report['pressure_fields'][0]
        self.assertEqual(field['code'], '999999')
        self.assertEqual(field['name'], 'MDC_PRESS_CUFF_SYS')
        self.assertEqual(field['hints'], ['systolic_pressure'])
        self.assertEqual(field['exact_identity_matches'], [])
        self.assertNotIn('123456789', json.dumps(report))

    def test_pressure_diagnostic_no_free_text_or_device_timestamps(self):
        body = signal_message('systolic_pressure', '123456789')
        body = body.replace(b'MDC_PRESS_CUFF_SYS', b'SYNTHETIC_PRIVATE_TEXT')
        body = body.replace(b'1.1.9.150301', b'SYNTHETIC_PRIVATE_SUBID')
        fields = body.rstrip(b'\r').split(b'\r')[-1].split(b'|')
        fields += [b''] * (15-len(fields))
        fields[14] = b'20261117123456'
        body = body[:body.index(b'OBX|')] + b'PID|||SYNTHETIC_PRIVATE_ID\r' + b'|'.join(fields) + b'\r'
        report = pressure_diagnostics(body)
        serialized = json.dumps(report)
        for text in ('SYNTHETIC_PRIVATE', '123456789', '20261117123456', 'PID|', 'OBX|', 'MSH|'):
            self.assertNotIn(text, serialized)
        self.assertTrue(report['pressure_fields'][0]['sample_time_present'])
        self.assertEqual(report['pressure_fields'][0]['name'], 'other')

    def test_pressure_inspect_exports_no_frames_or_numeric_readings(self):
        with tempfile.TemporaryDirectory() as folder:
            writer = SessionWriter(Path(folder)/'pressure', 'pressure_inspect')
            writer.consume(combined(signal_message('systolic_pressure', '120'),
                                    signal_message('diastolic_pressure', '80')), 1)
            self.assertEqual(writer.exported, [])
            self.assertFalse(list(writer.out.glob('*.bin')))
            self.assertFalse((writer.out/'observations.jsonl').exists())
            row = json.loads((writer.out/'pressure_diagnostics.jsonl').read_text())
            self.assertEqual(row['recognized_counts'],
                             {'systolic_pressure': 1, 'diastolic_pressure': 1})
            self.assertTrue(row['sample_times_equal'])
            self.assertFalse(any('value' in field for field in row['pressure_fields']))

    def test_pressure_inspect_distinguishes_separate_envelopes(self):
        systolic = pressure_diagnostics(signal_message('systolic_pressure', '120'))
        diastolic = pressure_diagnostics(signal_message('diastolic_pressure', '80'))
        self.assertEqual(systolic['recognized_counts'],
                         {'systolic_pressure': 1, 'diastolic_pressure': 0})
        self.assertEqual(diastolic['recognized_counts'],
                         {'systolic_pressure': 0, 'diastolic_pressure': 1})
        self.assertIsNone(systolic['sample_times_equal'])
        self.assertIsNone(diastolic['sample_times_equal'])


if __name__ == '__main__':
    unittest.main()
