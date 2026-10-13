import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import numpy as np
from scipy.io import loadmat, savemat

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from make_demo import generate
from pipeline import integrator, load_captures, summarize, windows, wilson


class PipelineTests(unittest.TestCase):
    def test_manchester_mapping(self):
        y = np.array([0, 1, 1, 0])
        signed = 2*y-1
        x = np.repeat(np.column_stack([signed, -signed]).reshape(-1), 5)
        np.testing.assert_array_equal(integrator(x, 10), y)

    def test_context_does_not_cross_frame(self):
        x = np.arange(20, dtype=np.float32)
        w = windows(x, 10, 1)
        self.assertEqual(w.shape, (2, 30))
        np.testing.assert_array_equal(w[0, :10], np.zeros(10))
        np.testing.assert_array_equal(w[1, -10:], np.zeros(10))
        np.testing.assert_array_equal(w[0, 10:20], x[:10])

    def test_failure_is_not_zero_ber(self):
        rows = [dict(status='error', bits=100, errors=0, detector_seconds=0)]
        result = summarize(rows)
        self.assertIsNone(result['ber'])
        self.assertEqual(result['exact_frame_delivery'], 0)
        self.assertEqual(result['bits_evaluated'], 0)
        self.assertGreater(wilson(0, 100)[1], 0)

    def test_session_leakage_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)/'data'
            generate(out, frames=2)
            path = out/'demo_test_0000.mat'
            data = {k: v for k, v in loadmat(path, squeeze_me=True).items() if not k.startswith('__')}
            meta = json.loads(str(data['metadata_json']))
            meta['session_id'] = 'demo_train'
            data['metadata_json'] = json.dumps(meta)
            savemat(path, data)
            with self.assertRaisesRegex(ValueError, 'vazamento'):
                load_captures(out)

    def test_invalid_aligned_length_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)/'data'
            generate(out, frames=2)
            path = out/'demo_train_0000.mat'
            data = {k: v for k, v in loadmat(path, squeeze_me=True).items() if not k.startswith('__')}
            data['rx_aligned'] = data['rx_aligned'][:-1]
            savemat(path, data)
            with self.assertRaisesRegex(ValueError, 'RX alinhado invalido'):
                load_captures(out)

    def test_independent_sync_not_silently_accepted(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)/'data'
            generate(out, frames=2)
            path = out/'demo_train_0000.mat'
            data = {k: v for k, v in loadmat(path, squeeze_me=True).items() if not k.startswith('__')}
            data['sync_mode'] = 'preamble'
            savemat(path, data)
            with self.assertRaisesRegex(ValueError, 'assisted_full_tx'):
                load_captures(out)

    def test_cli_train_evaluate(self):
        pipeline = Path(__file__).resolve().parents[1]/'pipeline.py'
        with tempfile.TemporaryDirectory() as tmp:
            data, run = Path(tmp)/'data', Path(tmp)/'run'
            generate(data, frames=3, bits=32)
            subprocess.run([sys.executable, str(pipeline), 'train', '--data', str(data),
                            '--out', str(run), '--epochs', '1'], check=True, capture_output=True)
            subprocess.run([sys.executable, str(pipeline), 'evaluate', '--data', str(data),
                            '--run', str(run)], check=True, capture_output=True)
            result = json.loads((run/'evaluation_test.json').read_text())
            for method in ('integrator', 'linear_ridge', 'cnn'):
                overall = result[method]['overall']
                self.assertEqual(overall['attempts'], 3)
                self.assertEqual(overall['failed_attempts'], 1)
                self.assertEqual(overall['bits_evaluated'], 64)


if __name__ == '__main__':
    unittest.main()
