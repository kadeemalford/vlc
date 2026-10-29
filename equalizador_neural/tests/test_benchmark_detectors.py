import json
from pathlib import Path
import sys
import tempfile
import unittest
from zipfile import ZipFile

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from benchmark_detectors import benchmark, fit_template, paired_session_bootstrap, template_bits
from make_demo import generate
from offline_dataset import load_audited_dataset
from reprocess_captures import reprocess_archive
from test_reprocess_captures import capture, write_zip


class BenchmarkTests(unittest.TestCase):
    def test_class_mean_template_detects_ideal_bits(self):
        c = dict(x=np.array([-1., 1., 1., -1.]), y=np.array([0, 1]), sps=2, status='ok')
        weights, intercept = fit_template([c])
        np.testing.assert_array_equal(template_bits(c['x'], 2, weights, intercept), c['y'])

    def test_paired_bootstrap_needs_sessions_not_noise_replicas(self):
        rows = [dict(ratio_db=0, status='ok', session_id=session, method=method,
                     bits_evaluated=100, bit_errors=0 if method == 'cnn' else 10)
                for session in ('a', 'b') for method in ('cnn', 'integrator')]
        result = paired_session_bootstrap(rows, 0, 'integrator')
        self.assertAlmostEqual(result['mean_session_ber_difference'], -.1)
        np.testing.assert_allclose(result['percentile95'], [-.1, -.1])
        one = paired_session_bootstrap(rows[:2]*20, 0, 'integrator')
        self.assertIsNone(one['percentile95'])
        self.assertEqual(one['sessions'], 1)

    def test_one_session_is_refused_before_creating_models(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_zip(root/'source.zip', [('one.mat', capture())])
            reprocess_archive(root/'source.zip', root/'data')
            with self.assertRaisesRegex(ValueError, 'one-session'):
                benchmark([root/'data'], root/'run', epochs=1)
            self.assertFalse((root/'run').exists())

    def test_full_augmented_benchmark_on_synthetic_sessions(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            generate(root/'demo', frames=3, bits=64)
            with ZipFile(root/'source.zip', 'w') as archive:
                for path in (root/'demo').glob('*.mat'):
                    archive.write(path, path.name)
            reprocess_archive(root/'source.zip', root/'audited')
            _, provenance = load_audited_dataset(root/'audited')
            curves = benchmark([root/'audited'], root/'run', augmentation=[-5, 0],
                               validation_ratios=[-3], evaluation_ratios=[-4, 1],
                               epochs=2, context=1, realizations=2)
            self.assertEqual(len(curves), 12)
            self.assertEqual({row['method'] for row in curves},
                             {'integrator', 'matched_template', 'linear_ridge', 'cnn'})
            manifest = json.loads((root/'run/manifest.json').read_text())
            self.assertEqual(manifest['state'], 'complete')
            self.assertTrue(manifest['synthetic_only'])
            self.assertEqual(manifest['sessions'], {'train': ['demo_train'],
                                                   'val': ['demo_val'], 'test': ['demo_test']})
            import csv
            with (root/'run/frames.csv').open() as stream:
                rows = list(csv.DictReader(stream))
            variants = {}
            for row in rows:
                key = row['capture_id'], row['ratio_db'], row['realization']
                if key in variants:
                    self.assertEqual(variants[key], row['variant_sha256'])
                variants[key] = row['variant_sha256']
            _, after = load_audited_dataset(root/'audited')
            self.assertEqual(provenance, after)
            self.assertTrue((root/'run/cnn.pt').exists())
            repeated = benchmark([root/'audited'], root/'repeated', augmentation=[-5, 0],
                                 validation_ratios=[-3], evaluation_ratios=[-4, 1],
                                 epochs=2, context=1, realizations=2)
            for a, b in zip(curves, repeated):
                self.assertEqual({k: v for k, v in a.items() if k != 'detector_seconds'},
                                 {k: v for k, v in b.items() if k != 'detector_seconds'})


if __name__ == '__main__':
    unittest.main()
