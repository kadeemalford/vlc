from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from monitor_capture import MllpFramer, SessionWriter, compact_frame, parse_rates


def message(signal='pulse_rate', value='80', status='F', units='MDC_DIM_BEAT_PER_MIN'):
    code, name, sub_id = (('149530', 'MDC_PULS_OXIM_PULS_RATE', '1.3.1.149530')
                          if signal == 'pulse_rate' else ('147842', 'MDC_ECG_HEART_RATE', '1.7.4.147842'))
    return (f'MSH|^~\\&|SYNTHETIC||||20261110000000||ORU^R01|1|P|2.3\r'
            f'PID|||SYNTHETIC_PRIVATE_ID\r'
            f'OBX|1|NM|{code}^{name}^MDC|{sub_id}|{value}|264864^{units}^MDC|||||{status}\r').encode()


def envelope(body):
    return b'\x0b'+body+b'\x1c\r'


class MonitorTests(unittest.TestCase):
    def test_fragmented_and_coalesced_mllp(self):
        a, b = message(value='80'), message(value='81')
        wire = envelope(a)+envelope(b)
        framer = MllpFramer()
        result = []
        for byte in wire:
            result.extend(framer.feed(bytes([byte])))
        self.assertEqual(result, [a, b])
        self.assertEqual(framer.buffer, b'')
        self.assertEqual(MllpFramer().feed(wire), [a, b])

    def test_partial_message_never_parsed(self):
        framer = MllpFramer()
        self.assertEqual(framer.feed(envelope(message())[:-1]), [])
        self.assertTrue(framer.buffer)
        self.assertEqual(framer.feed(b'\r'), [message()])

    def test_unframed_oversized_and_nested_rejected(self):
        for wire in (message(), b'\x0b'+b'a'*20, envelope(b'abc\x0bdef')):
            with self.assertRaises(ValueError):
                MllpFramer(max_message_bytes=10).feed(wire)

    def test_hr_and_pr_are_distinct(self):
        pulse, heart = parse_rates(message())[0], parse_rates(message('heart_rate'))[0]
        self.assertEqual(compact_frame(pulse), b'!#MDPR0080')
        self.assertEqual(compact_frame(heart), b'!#MDHR0080')
        self.assertTrue(pulse['eligible'])
        self.assertNotIn('SYNTHETIC_PRIVATE_ID', str(pulse))

    def test_invalid_missing_and_decimal_not_fabricated_or_rounded(self):
        for value in ('', 'NaN', 'Infinity', '-100', '0', '80.5', '10000', 'PRIVATE_STRING'):
            record = parse_rates(message(value=value))[0]
            self.assertFalse(record['eligible'], value)
            self.assertIsNone(record['value_bpm'])
            with self.assertRaises(ValueError):
                compact_frame(record)
        self.assertFalse(parse_rates(message(status='X'))[0]['eligible'])
        self.assertFalse(parse_rates(message(units='MDC_DIM_PERCENT'))[0]['eligible'])

    def test_unknown_signals_and_duplicate_obx(self):
        unknown = message().replace(b'MDC_PULS_OXIM_PULS_RATE', b'MDC_PULS_OXIM_SAT_O2')
        self.assertEqual(parse_rates(unknown), [])
        body = message()
        duplicated = body+body[body.index(b'OBX|'):]
        self.assertTrue(all(not r['eligible'] for r in parse_rates(duplicated)))

    def test_inspect_saves_only_whitelisted_observations(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)/'inspect'
            writer = SessionWriter(out, 'inspect')
            writer.consume(message(), 1)
            self.assertEqual(writer.exported, [])
            self.assertEqual(list(out.glob('*.bin')), [])
            stored = (out/'observations.jsonl').read_text()
            self.assertNotIn('PID', stored)
            self.assertNotIn('SYNTHETIC_PRIVATE_ID', stored)
            self.assertIn('pulse_rate', stored)

    def test_selected_signal_only_exact_bytes_and_refuse_existing(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)/'capture'
            writer = SessionWriter(out, 'pulse_rate')
            writer.consume(message('heart_rate'), 0)
            writer.consume(message(value='81'), 1)
            self.assertEqual(len(writer.exported), 1)
            self.assertEqual((out/'monitor_000001.bin').read_bytes(), b'!#MDPR0081')
            with self.assertRaises(FileExistsError):
                SessionWriter(out, 'pulse_rate')


if __name__ == '__main__':
    unittest.main()
