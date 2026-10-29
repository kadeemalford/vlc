"""Offline regression tests; NumPy/SciPy only, no torch or instruments."""
from io import BytesIO
import json
from pathlib import Path
import stat
import sys
import tempfile
import unittest
import warnings
from zipfile import ZipFile, ZipInfo

import numpy as np
from scipy.io import loadmat, savemat

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from capture_sync import manchester_bits, synchronize_samples
from reprocess_captures import reprocess_archive, sha256


PILOT_ZIP = Path(__file__).resolve().parents[2]/'baseline_20261015_175101.zip'
PILOT_SHA256 = 'e0653b423bfb800903f75f5b13b66db7aa32ac848e91ef4d8b3e04f925a339cf'


def manchester(bits):
    signed = 2*np.asarray(bits, dtype=float)-1
    return np.repeat(np.column_stack([signed, -signed]).reshape(-1), 5)


def capture(capture_id='capture_0001', status='ok', split='train', truncated=False):
    bits = np.random.default_rng(42).integers(0, 2, 60)
    tx = manchester(bits)
    raw = np.r_[np.zeros(17), .8*tx, np.zeros(100), 1.1*tx[:-5]] if truncated else np.r_[np.zeros(17), tx]
    meta = dict(capture_id=capture_id, session_id='session_01', condition_id='fixed',
                split=split, payload_seed=42, operator_note='Original metadata: não alterar')
    return dict(metadata_json=json.dumps(meta, ensure_ascii=False), tx_bits=bits,
                tx_samples=tx, rx_raw=raw, rx_aligned=.8*tx if status == 'ok' else [],
                sps=10, bit_rate=1e6, rx_sample_rate=1e7, tx_sample_rate=1e7,
                status=status, stage='synchronization', sync_mode='assisted_full_tx',
                error_message='Original synchronization error' if status == 'error' else '',
                upload_seconds=.15, acquisition_seconds=.08, sync_seconds=.01,
                total_seconds=.24)


def mat_bytes(data):
    stream = BytesIO()
    savemat(stream, data)
    return stream.getvalue()


def write_zip(path, records):
    with ZipFile(path, 'w') as archive:
        for name, data in records:
            archive.writestr(name, mat_bytes(data))


class SynchronizationTests(unittest.TestCase):
    def test_truncated_peak_does_not_hide_complete_copy(self):
        d = capture(status='error', truncated=True)
        aligned, info = synchronize_samples(d['tx_samples'], d['rx_raw'])
        full = np.convolve(d['rx_raw'], d['tx_samples'][::-1])
        global_lag = np.argmax(abs(full))-len(d['tx_samples'])+1
        self.assertGreater(global_lag+len(d['tx_samples']), len(d['rx_raw']))
        self.assertTrue(info['accepted'])
        self.assertEqual(info['start_sample'], 18)
        self.assertEqual(info['lag_samples'], 17)
        np.testing.assert_allclose(aligned, .8*d['tx_samples'])
        np.testing.assert_array_equal(manchester_bits(aligned, 10), d['tx_bits'])

    def test_inversion_and_dc_preserve_original_amplitude(self):
        tx = manchester([0, 1, 1, 0, 1, 0, 0, 1])
        rx = np.r_[np.zeros(9), -2*tx, np.zeros(13)]+7
        aligned, info = synchronize_samples(tx, rx, .8)
        self.assertEqual(info['lag_samples'], 9)
        self.assertEqual(info['polarity'], -1)
        self.assertAlmostEqual(info['score'], 1.)
        np.testing.assert_allclose(aligned, 2*tx-7)

    def test_last_complete_window(self):
        tx = manchester([1, 1, 0, 1, 0, 0, 0, 1])
        aligned, info = synchronize_samples(tx, np.r_[np.zeros(11), tx])
        self.assertEqual(info['start_sample'], 12)
        np.testing.assert_array_equal(aligned, tx)

    def test_short_and_flat_records_are_rejected(self):
        tx = manchester([0, 1, 0, 0])
        for rx, reason in [(tx[:-1], 'record_shorter_than_frame'),
                           (np.ones(100), 'no_nonconstant_window')]:
            with self.subTest(reason=reason):
                aligned, info = synchronize_samples(tx, rx)
                self.assertFalse(info['accepted'])
                self.assertEqual(info['reason'], reason)
                self.assertEqual(len(aligned), 0)

    def test_low_score_is_rejected(self):
        tx = manchester([0, 1, 0, 0, 1, 0, 1, 1])
        rx = tx.copy()
        rx[:10] *= -1
        aligned, info = synchronize_samples(tx, rx, .99)
        self.assertFalse(info['accepted'])
        self.assertEqual(info['reason'], 'correlation_below_threshold')
        self.assertEqual(len(aligned), 0)

    def test_invalid_inputs(self):
        tx = manchester([0, 1])
        for threshold in [0, -1, 1.01, np.nan, np.inf]:
            with self.subTest(threshold=threshold), self.assertRaises(ValueError):
                synchronize_samples(tx, tx, threshold)
        for reference, rx in [(np.ones(10), np.ones(20)), (tx, [np.nan]*30),
                              (np.ones((2, 2)), tx), (tx+1j, tx)]:
            with self.assertRaises(ValueError):
                synchronize_samples(reference, rx)


class ReprocessingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root/'source.zip'
        self.out = self.root/'derived'

    def test_reports_provenance_and_source_bytes_are_preserved(self):
        original = capture('failed', status='error', truncated=True)
        write_zip(self.source, [('captures/good.mat', capture()), ('captures/failed.mat', original)])
        before = self.source.read_bytes()
        result = reprocess_archive(self.source, self.out, expected_sha256=sha256(before))
        self.assertEqual(self.source.read_bytes(), before)
        self.assertEqual(result['source_status_counts'], {'ok': 1, 'error': 1})
        self.assertEqual(result['accepted'], 2)
        self.assertEqual(result['bits_evaluated'], 120)
        self.assertEqual(result['bit_errors'], 0)
        self.assertEqual(result['recovered_capture_ids'], ['failed'])
        derived = loadmat(self.out/'captures/failed.mat', simplify_cells=True)
        self.assertEqual(derived['source_status'], 'error')
        self.assertEqual(derived['source_record']['status'], 'error')
        self.assertEqual(derived['source_record']['error_message'], original['error_message'])
        self.assertEqual(derived['source_record']['rx_aligned'].size, 0)
        self.assertEqual(derived['metadata_json'], original['metadata_json'])
        self.assertEqual(derived['total_seconds'], original['total_seconds'])
        self.assertEqual(derived['sync_seconds'], original['sync_seconds'])
        self.assertGreaterEqual(derived['reprocess_seconds'], 0)
        np.testing.assert_array_equal(derived['rx_raw'], original['rx_raw'])
        manifest = json.loads((self.out/'manifest.json').read_text())
        self.assertEqual(manifest['state'], 'complete')
        self.assertEqual(manifest['source_archive_sha256'], sha256(before))
        for item in manifest['outputs']:
            self.assertEqual(item['derived_sha256'], sha256((self.out/item['file']).read_bytes()))
        self.assertTrue((self.out/'frames.csv').exists())
        self.assertEqual(len(result['duplicate_payload_groups']), 1)

    def test_missing_source_signal_stays_unavailable(self):
        d = capture(status='error')
        d.update(rx_raw=[], rx_sample_rate=np.nan, stage='acquisition', error_message='read failed')
        write_zip(self.source, [('missing.mat', d)])
        result = reprocess_archive(self.source, self.out)
        self.assertEqual(result['accepted'], 0)
        self.assertEqual(result['bits_evaluated'], 0)
        self.assertIsNone(result['ber'])
        derived = loadmat(self.out/'captures/capture_0001.mat', simplify_cells=True)
        self.assertEqual(derived['status'], 'error')
        self.assertEqual(derived['source_record']['stage'], 'acquisition')

    def test_repeated_runs_preserve_numeric_results_and_metadata(self):
        write_zip(self.source, [('good.mat', capture())])
        first = reprocess_archive(self.source, self.out)
        second_out = self.root/'second'
        second = reprocess_archive(self.source, second_out)
        self.assertEqual(first, second)
        a = loadmat(self.out/'captures/capture_0001.mat', simplify_cells=True)
        b = loadmat(second_out/'captures/capture_0001.mat', simplify_cells=True)
        np.testing.assert_array_equal(a['rx_aligned'], b['rx_aligned'])
        self.assertEqual(a['sync_info'], b['sync_info'])
        self.assertEqual(a['metadata_json'], b['metadata_json'])

    def test_rejected_alignment_is_not_zero_ber(self):
        d = capture()
        d['rx_raw'] = np.zeros_like(d['rx_raw'])
        write_zip(self.source, [('zero.mat', d)])
        result = reprocess_archive(self.source, self.out)
        self.assertEqual(result['newly_rejected_capture_ids'], ['capture_0001'])
        self.assertEqual(result['bits_evaluated'], 0)
        self.assertIsNone(result['ber'])
        self.assertEqual(result['exact_frame_delivery'], 0)

    def test_existing_output_and_checksum_mismatch_fail_without_writing(self):
        write_zip(self.source, [('good.mat', capture())])
        with self.assertRaisesRegex(ValueError, 'checksum'):
            reprocess_archive(self.source, self.out, expected_sha256='0'*64)
        self.assertFalse(self.out.exists())
        self.out.mkdir()
        sentinel = self.out/'keep.txt'
        sentinel.write_text('user work')
        with self.assertRaises(FileExistsError):
            reprocess_archive(self.source, self.out)
        self.assertEqual(sentinel.read_text(), 'user work')

    def test_unsafe_archive_paths_rejected_without_extraction(self):
        for name in ['../escape.mat', '/escape.mat', 'C:/escape.mat', 'dir\\escape.mat']:
            with self.subTest(name=name):
                write_zip(self.source, [(name, capture())])
                with self.assertRaisesRegex(ValueError, 'unsafe ZIP'):
                    reprocess_archive(self.source, self.out)
                self.assertFalse(self.out.exists())
        self.assertFalse((self.root.parent/'escape.mat').exists())

    def test_symlink_archive_member_rejected(self):
        info = ZipInfo('link.mat')
        info.create_system = 3
        info.external_attr = (stat.S_IFLNK | 0o777) << 16
        with ZipFile(self.source, 'w') as archive:
            archive.writestr(info, 'target.mat')
        with self.assertRaisesRegex(ValueError, 'unsafe ZIP'):
            reprocess_archive(self.source, self.out)

    def test_duplicate_members_and_ids_rejected(self):
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            write_zip(self.source, [('same.mat', capture()), ('same.mat', capture('other'))])
        with self.assertRaisesRegex(ValueError, 'duplicate ZIP'):
            reprocess_archive(self.source, self.out)
        write_zip(self.source, [('one.mat', capture()), ('two.mat', capture())])
        with self.assertRaisesRegex(ValueError, 'duplicate capture_id'):
            reprocess_archive(self.source, self.out)
        write_zip(self.source, [('one.mat', capture('Frame')), ('two.mat', capture('frame'))])
        with self.assertRaisesRegex(ValueError, 'duplicate capture_id'):
            reprocess_archive(self.source, self.out)
        self.assertFalse(self.out.exists())

    def test_session_leakage_rejected(self):
        write_zip(self.source, [('one.mat', capture()), ('two.mat', capture('second', split='test'))])
        with self.assertRaisesRegex(ValueError, 'session crosses splits'):
            reprocess_archive(self.source, self.out)
        self.assertFalse(self.out.exists())

    def test_malformed_contract_and_wrong_rates_rejected(self):
        for change, message in [({'rx_sample_rate': 5e6}, 'resampling'),
                                ({'tx_bits': [0, 2]}, 'binary'),
                                ({'tx_samples': np.ones(600)}, 'Manchester'),
                                ({'rx_aligned': [1, 2]}, 'incomplete'),
                                ({'metadata_json': '{}'}, 'metadata'),
                                ({'sync_mode': 'preamble'}, 'assisted_full_tx')]:
            with self.subTest(change=list(change)):
                d = capture()
                d.update(change)
                write_zip(self.source, [('bad.mat', d)])
                with self.assertRaisesRegex(ValueError, message):
                    reprocess_archive(self.source, self.out)
                self.assertFalse(self.out.exists())

    def test_size_limit_rejected_before_reading(self):
        from unittest.mock import patch
        write_zip(self.source, [('good.mat', capture())])
        with patch('reprocess_captures.MAX_MEMBER_BYTES', 1):
            with self.assertRaisesRegex(ValueError, 'size limits'):
                reprocess_archive(self.source, self.out)
        self.assertFalse(self.out.exists())

    def test_corrupt_mat_rejected_before_output_creation(self):
        with ZipFile(self.source, 'w') as archive:
            archive.writestr('bad.mat', b'not a MAT file')
        with self.assertRaises(ValueError):
            reprocess_archive(self.source, self.out)
        self.assertFalse(self.out.exists())

    def test_write_failure_is_recorded_without_cleaning_output(self):
        from unittest.mock import patch
        write_zip(self.source, [('good.mat', capture())])
        before = self.source.read_bytes()
        with patch('reprocess_captures.savemat', side_effect=OSError('disk failure')):
            with self.assertRaises(OSError):
                reprocess_archive(self.source, self.out)
        manifest = json.loads((self.out/'manifest.json').read_text())
        self.assertEqual(manifest['state'], 'failed')
        self.assertIn('disk failure', manifest['error'])
        self.assertEqual(self.source.read_bytes(), before)
        with self.assertRaises(FileExistsError):
            reprocess_archive(self.source, self.out)

    @unittest.skipUnless(PILOT_ZIP.exists(), 'Local pilot ZIP is not distributed with tests')
    def test_local_pilot_archive(self):
        result = reprocess_archive(PILOT_ZIP, self.out, expected_sha256=PILOT_SHA256)
        self.assertEqual(result['attempts'], 100)
        self.assertEqual(result['source_status_counts'], {'ok': 99, 'error': 1})
        self.assertEqual(result['accepted'], 100)
        self.assertEqual(result['bits_evaluated'], 40000)
        self.assertEqual(result['source_bits_evaluated'], 39600)
        self.assertEqual(result['bit_errors'], 0)
        self.assertEqual(result['recovered_capture_ids'], ['baseline_20261015_175101_0042'])
        self.assertEqual(result['duplicate_raw_groups'], [])
        self.assertEqual(result['duplicate_payload_groups'], [])
        self.assertEqual(result['sessions'], {'piloto_funcional_20261015': 100})
        self.assertEqual(result['splits'], {'train': 100})
        recovered = loadmat(self.out/'captures/baseline_20261015_175101_0042.mat', simplify_cells=True)
        self.assertEqual(recovered['sync_info']['start_sample'], 2006)
        self.assertAlmostEqual(recovered['sync_info']['score'], .9085408205223925, places=10)


if __name__ == '__main__':
    unittest.main()
