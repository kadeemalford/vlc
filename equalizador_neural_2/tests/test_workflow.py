import json
from pathlib import Path
import sys
import tempfile
import unittest
from zipfile import ZipFile

import numpy as np
from scipy.io import loadmat, savemat

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from make_demo import generate
from campaign import prepare
from benchmark import dfe_predict, feedback_features, run
from compare_rates import compare
from reprocess_captures import file_sha256, read_archive


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_feedback_uses_only_previous_bits_and_resets(self):
        np.testing.assert_array_equal(feedback_features([1, 0, 1], 2), [[0, 0], [1, 0], [-1, 1]])
        # Decision is solely previous decision plus positive bias: recursive output is all ones.
        weights = np.array([0., 1., .2])
        np.testing.assert_array_equal(dfe_predict(np.zeros((4, 1)), weights, 1), [1, 1, 1, 1])
        np.testing.assert_array_equal(dfe_predict(np.zeros((4, 1)), weights, 1), [1, 1, 1, 1])

    def test_multirate_audit_and_complete_neural_classical_benchmark(self):
        generate(self.root/'raw', frames=2, bits=64)
        hashes = {p: file_sha256(p) for p in (self.root/'raw').rglob('*.mat')}
        manifest = prepare([self.root/'raw'], self.root/'audit')
        self.assertEqual(manifest['state'], 'complete')
        self.assertEqual(len(manifest['datasets']), 2)
        for key in manifest['datasets']:
            root = self.root/'audit'/key
            self.assertTrue((root/'characterization/spectra.csv').exists())
            curves = run([root], self.root/f'benchmark_{key}', epochs=2, context=1, feedback=2)
            self.assertEqual({r['method'] for r in curves},
                             {'integrator', 'matched_template', 'linear_ridge', 'cnn', 'dfe'})
            result = json.loads((self.root/f'benchmark_{key}'/'manifest.json').read_text())
            self.assertEqual(result['state'], 'complete')
            self.assertEqual(result['bit_rate'], int(key.split('_')[1]))
        key = next(iter(manifest['datasets']))
        repeated = run([self.root/'audit'/key], self.root/'repeat', epochs=2, context=1, feedback=2)
        original = json.loads((self.root/f'benchmark_{key}'/'summary.json').read_text())['curves']
        self.assertEqual([{k: v for k, v in r.items() if k != 'detector_seconds'} for r in original],
                         [{k: v for k, v in r.items() if k != 'detector_seconds'} for r in repeated])
        for name, digest in manifest['outputs_sha256'].items():
            self.assertEqual(file_sha256(self.root/'audit'/name), digest)
        runs = [self.root/f'benchmark_{key}' for key in manifest['datasets']]
        rows = compare(runs, self.root/'comparison')
        self.assertEqual(len(rows), 10)
        self.assertTrue((self.root/'comparison/ber.svg').is_file())
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            compare([runs[0], runs[0]], self.root/'duplicate_comparison')
        with (runs[0]/'curves.csv').open('a') as stream:
            stream.write('changed')
        with self.assertRaisesRegex(ValueError, 'changed'):
            compare(runs, self.root/'modified_comparison')
        self.assertEqual(hashes, {p: file_sha256(p) for p in hashes})
        with self.assertRaises(FileExistsError):
            prepare([self.root/'raw'], self.root/'audit')

    def test_pilot_cannot_train_and_mixed_rates_cannot_train_together(self):
        generate(self.root/'raw', frames=1, bits=64)
        prepare([self.root/'raw'/'train'], self.root/'pilot')
        with self.assertRaisesRegex(ValueError, 'one-session'):
            run([self.root/'pilot/rate_1000000_sps_10'], self.root/'blocked', epochs=1)
        self.assertFalse((self.root/'blocked').exists())
        with self.assertRaisesRegex(ValueError, 'protocol'):
            run([self.root/'pilot/rate_1000000_sps_10', self.root/'pilot/rate_2000000_sps_10'],
                self.root/'mixed', epochs=1)
        self.assertFalse((self.root/'mixed').exists())

    def test_bad_sampling_is_rejected_before_output(self):
        generate(self.root/'raw', frames=1, bits=64, rates=(1000000,))
        path = next((self.root/'raw').rglob('*.mat'))
        data = loadmat(path, simplify_cells=True)
        data['rx_sample_rate'] = 9e6
        savemat(path, {k: v for k, v in data.items() if not k.startswith('__')})
        with self.assertRaisesRegex(ValueError, 'unequal sample rates'):
            prepare([self.root/'raw'], self.root/'bad')
        self.assertFalse((self.root/'bad').exists())

    def test_duplicate_ids_are_rejected_before_output(self):
        generate(self.root/'raw', frames=1, bits=64, rates=(1000000,))
        with self.assertRaisesRegex(ValueError, 'Duplicate capture'):
            prepare([self.root/'raw', self.root/'raw'], self.root/'duplicate')
        self.assertFalse((self.root/'duplicate').exists())

    def test_existing_real_pilot_compatibility_without_training(self):
        archive_path = Path(__file__).resolve().parents[2]/'baseline_20261015_175101.zip'
        if not archive_path.is_file():
            self.skipTest('Original pilot ZIP is not distributed with the code')
        before = file_sha256(archive_path)
        self.assertEqual(before, 'e0653b423bfb800903f75f5b13b66db7aa32ac848e91ef4d8b3e04f925a339cf')
        records = read_archive(archive_path)  # Validate archive before writing safe local IDs.
        raw = self.root/'pilot_raw'
        raw.mkdir()
        with ZipFile(archive_path) as archive:
            for record in records:
                (raw/(record['meta']['capture_id']+'.mat')).write_bytes(archive.read(record['source_member']))
        prepare([raw], self.root/'pilot_compatibility')
        root = self.root/'pilot_compatibility/rate_1000000_sps_10'
        summary = json.loads((root/'characterization/summary.json').read_text())
        self.assertEqual(summary['sessions'][0]['accepted'], 100)
        self.assertEqual(summary['sessions'][0]['bits'], 40000)
        self.assertEqual(summary['sessions'][0]['errors'], 0)
        with self.assertRaisesRegex(ValueError, 'one-session'):
            run([root], self.root/'not_a_real_training_run', epochs=1)
        self.assertFalse((self.root/'not_a_real_training_run').exists())
        self.assertEqual(file_sha256(archive_path), before)


if __name__ == '__main__':
    unittest.main()
