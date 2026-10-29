import json
from pathlib import Path
import sys
import tempfile
import unittest

import numpy as np
from scipy.special import ndtr

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from awgn import add_awgn, frame_error_probability, integrator_error_probabilities
from awgn_sweep import run_sweep
from capture_sync import manchester_bits
from export_results import export_results
from offline_dataset import load_audited_dataset, require_independent_splits
from reprocess_captures import reprocess_archive
from test_reprocess_captures import capture, manchester, write_zip


class NoiseTests(unittest.TestCase):
    def setUp(self):
        self.bits = np.random.default_rng(10).integers(0, 2, 400)
        self.x = manchester(self.bits)

    def test_clean_copy_and_immutability(self):
        before = self.x.copy()
        noisy, info = add_awgn(self.x, 'capture', 'checksum', None)
        np.testing.assert_array_equal(noisy, self.x)
        noisy[0] = 30
        np.testing.assert_array_equal(self.x, before)
        self.assertEqual(info['sigma'], 0)

    def test_deterministic_keyed_noise_independent_of_call_order(self):
        first, recipe = add_awgn(self.x, 'a', 'hash', -2, 4, 2)
        for args in [('b', 'hash', -2, 4, 2), ('a', 'different', -2, 4, 2),
                     ('a', 'hash', 0, 4, 2), ('a', 'hash', -2, 5, 2), ('a', 'hash', -2, 4, 3)]:
            other, info = add_awgn(self.x, *args)
            self.assertNotEqual(recipe['noise_seed_hex'], info['noise_seed_hex'])
            self.assertFalse(np.array_equal(first, other))
        again, again_recipe = add_awgn(self.x, 'a', 'hash', -2, 4, 2)
        np.testing.assert_array_equal(first, again)
        self.assertEqual(recipe, again_recipe)
        positive_zero, _ = add_awgn(self.x, 'a', 'hash', 0.)
        negative_zero, _ = add_awgn(self.x, 'a', 'hash', -0.)
        np.testing.assert_array_equal(positive_zero, negative_zero)

    def test_expected_power_and_white_gaussian_draw(self):
        x = np.tile([-1., 1.], 100000)
        noisy, info = add_awgn(x, 'power', 'hash', 3)
        noise = noisy-x
        self.assertAlmostEqual(info['expected_noise_power'], 10**(-.3))
        self.assertLess(abs(np.mean(noise)), .01)
        self.assertLess(abs(np.mean(noise**2)/info['expected_noise_power']-1), .02)
        self.assertLess(abs(np.corrcoef(noise[:-1], noise[1:])[0, 1]), .01)
        self.assertEqual(info['realized_noise_power'], float(np.mean(noise**2)))

    def test_no_clipping_or_rescaling_and_dc_does_not_set_power(self):
        noisy, info = add_awgn(self.x+1000, 'capture', 'hash', -50)
        self.assertEqual(info['captured_ac_power'], 1)
        self.assertGreater(np.max(abs(noisy)), 127)
        self.assertEqual(noisy.dtype, np.float64)

    def test_ideal_integrator_matches_closed_form(self):
        probabilities = integrator_error_probabilities(self.x, self.bits, 10, 2.)
        np.testing.assert_allclose(probabilities, ndtr(-np.sqrt(10)/2))
        self.assertAlmostEqual(frame_error_probability(np.array([.1, .2])), .28)
        self.assertEqual(frame_error_probability(np.array([1., .2])), 1)

    def test_monte_carlo_matches_conditional_prediction(self):
        bits = np.random.default_rng(0).integers(0, 2, 30000)
        x = manchester(bits)
        noisy, info = add_awgn(x, 'large', 'hash', -5)
        p = integrator_error_probabilities(x, bits, 10, info['sigma'])
        errors = np.sum(manchester_bits(noisy, 10) != bits)
        self.assertLess(abs(errors-p.sum()), 5*np.sqrt(np.sum(p*(1-p))))

    def test_zero_noise_uses_exact_tie_convention(self):
        x = np.zeros(20)
        np.testing.assert_array_equal(integrator_error_probabilities(x, [0, 1], 10, 0), [0, 1])

    def test_invalid_noise_parameters(self):
        for db in [np.nan, np.inf, 101]:
            with self.assertRaises(ValueError):
                add_awgn(self.x, 'a', 'hash', db)
        with self.assertRaises(ValueError):
            add_awgn(np.ones(20), 'a', 'hash', 0)
        with self.assertRaises(ValueError):
            add_awgn(self.x, 'a', 'hash', 0, seed=-1)


class AuditedSweepTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        source = self.root/'source.zip'
        write_zip(source, [('one.mat', capture()), ('two.mat', capture('recovered', 'error', truncated=True))])
        self.data = self.root/'data'
        reprocess_archive(source, self.data)

    def test_sweep_is_reproducible_and_clean_baseline_unchanged(self):
        first = run_sweep(self.data, self.root/'run1', [-10, 0, 10], 3, 77, plots=False)
        second = run_sweep(self.data, self.root/'run2', [-10, 0, 10], 3, 77, plots=False)
        self.assertEqual(first, second)
        baseline = first['curves'][0]
        self.assertEqual(baseline['bit_errors'], 0)
        self.assertEqual(baseline['bits_evaluated'], 120)
        self.assertEqual(first['unique_physical_captures'], 2)
        self.assertEqual(first['curves'][1]['bits_evaluated'], 360)
        a = (self.root/'run1/frames.csv').read_bytes()
        b = (self.root/'run2/frames.csv').read_bytes()
        self.assertEqual(a, b)
        manifest = json.loads((self.root/'run1/manifest.json').read_text())
        self.assertEqual(manifest['state'], 'complete')
        self.assertIn('frames.csv', manifest['outputs_sha256'])
        with self.assertRaises(FileExistsError):
            run_sweep(self.data, self.root/'run1', [0], plots=False)

    def test_modified_capture_is_rejected(self):
        path = self.data/'captures/capture_0001.mat'
        path.write_bytes(path.read_bytes()+b'changed')
        with self.assertRaisesRegex(ValueError, 'modified'):
            run_sweep(self.data, self.root/'out', [0], plots=False)
        self.assertFalse((self.root/'out').exists())

    def test_pre_sync_noise_counts_rejections_separately(self):
        result = run_sweep(self.data, self.root/'pre', [-50], 2, 9,
                           plots=False, point='pre-synchronization')
        self.assertEqual(result['curves'][0]['accepted'], 2)
        noisy = result['curves'][1]
        self.assertEqual(noisy['rejected'], 4)
        self.assertEqual(noisy['bits_evaluated'], 0)
        self.assertIsNone(noisy['ber'])
        self.assertIsNone(noisy['expected_conditional_ber'])
        self.assertEqual(noisy['exact_frame_delivery'], 0)

    def test_incomplete_manifest_is_rejected(self):
        path = self.data/'manifest.json'
        manifest = json.loads(path.read_text())
        manifest['state'] = 'failed'
        path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, 'complete'):
            load_audited_dataset(self.data)

    def test_one_session_cannot_train_a_model(self):
        captures, _ = load_audited_dataset(self.data)
        with self.assertRaisesRegex(ValueError, 'one-session'):
            require_independent_splits(captures)

    def test_aliasing_sessions_or_payloads_does_not_create_independent_test(self):
        captures = [dict(meta=dict(session_id=split, split=split), source_sha256=split,
                         payload_sha256='same', raw_sha256=split) for split in ('train', 'val', 'test')]
        with self.assertRaisesRegex(ValueError, 'payload_sha256'):
            require_independent_splits(captures)

    def test_unsafe_manifest_path_is_rejected(self):
        path = self.data/'manifest.json'
        manifest = json.loads(path.read_text())
        manifest['outputs'][0]['file'] = '../escape.mat'
        path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, 'unsafe'):
            load_audited_dataset(self.data)

    def test_summary_export_checks_hashes_and_excludes_raw_replicas(self):
        run_sweep(self.data, self.root/'run', [0], 1, plots=False)
        provenance = export_results(self.root/'run', self.root/'export')
        self.assertEqual(set(provenance['exported_sha256']), {'summary.json', 'curves.csv'})
        self.assertFalse((self.root/'export/frames.csv').exists())
        with self.assertRaises(FileExistsError):
            export_results(self.root/'run', self.root/'export')
        with (self.root/'run/frames.csv').open('a') as stream:
            stream.write('modified')
        with self.assertRaisesRegex(ValueError, 'modified'):
            export_results(self.root/'run', self.root/'second_export')
        self.assertFalse((self.root/'second_export').exists())


if __name__ == '__main__':
    unittest.main()
