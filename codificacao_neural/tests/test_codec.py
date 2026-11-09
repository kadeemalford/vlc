from pathlib import Path
import sys
import tempfile
import unittest

import numpy as np
from scipy.io import loadmat, savemat

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from codec import byte_bits, conformance, decode, encode, fit, load_model, sha256
from packets import pack_packet, unpack_packet
from workflow import prepare, read_bits, receive, train


class CodecTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.models = tempfile.TemporaryDirectory()
        cls.root = Path(cls.models.name)
        cls.training = train(cls.root/'model', seed=42)
        cls.model_path = cls.root/'model/model.pt'
        cls.model = load_model(cls.model_path)

    @classmethod
    def tearDownClass(cls):
        cls.models.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.out = Path(self.temp.name)
        self.source = self.out/'synthetic.bin'
        self.source.write_bytes(b'!#MDHR0080|!#VAMX11')

    def prepare(self):
        manifest = prepare(self.model_path, self.source, self.out/'tx')
        return manifest, sorted((self.out/'tx').glob('packet_*.mat'))

    def test_exhaustive_alphabet_is_exact_and_expands(self):
        result = conformance(self.model)
        self.assertEqual(result['byte_errors'], 0)
        self.assertEqual(result['unique_codewords'], 256)
        self.assertFalse(result['security_claim'])
        self.assertEqual(len(encode(self.model, bytes(range(256)))), 512)
        self.assertEqual(decode(self.model, encode(self.model, bytes(range(256)))), bytes(range(256)))
        np.testing.assert_array_equal(byte_bits(b'\x80'), [[1, 0, 0, 0, 0, 0, 0, 0]])

    def test_training_reproducible_and_other_seeds_conform(self):
        for seed in (42, 43, 44):
            model, result = fit(seed)
            self.assertEqual(result['byte_errors'], 0)
            if seed == 42:
                self.assertEqual(encode(model, bytes(range(256))), encode(self.model, bytes(range(256))))

    def test_serialized_ideal_roundtrip_and_bypass_control(self):
        manifest, paths = self.prepare()
        self.assertEqual(len(paths), 2)
        self.assertLessEqual(max(r['bits'] for r in manifest['packets']), 500)
        before = {p: sha256(p) for p in paths}
        result = receive(self.model_path, paths, self.out/'ideal', ideal=True, reference=self.source)
        self.assertTrue(result['complete'])
        self.assertTrue(result['exact_match'])
        self.assertEqual(result['byte_errors'], 0)
        bypass = receive(self.model_path, paths, self.out/'bypass', ideal=True,
                         reference=self.source, bypass=True)
        self.assertFalse(bypass['exact_match'])
        self.assertEqual(bypass['output_bytes'], 2*self.source.stat().st_size)
        self.assertEqual(before, {p: sha256(p) for p in paths})
        with self.assertRaises(FileExistsError):
            prepare(self.model_path, self.source, self.out/'tx')

    def test_physical_reader_never_falls_back_to_tx(self):
        _, paths = self.prepare()
        raw = self.out/'rx'
        raw.mkdir()
        for index, path in enumerate(paths):
            bits = loadmat(path, simplify_cells=True)['tx_bits']
            bipolar = 2*bits-1
            samples = np.repeat(np.column_stack([bipolar, -bipolar]).reshape(-1), 5)
            savemat(raw/f'{index}.mat', dict(rx_aligned=samples, sps=10, status='ok', tx_bits=1-bits))
        result = receive(self.model_path, sorted(raw.glob('*.mat')), self.out/'rx_result',
                         reference=self.source)
        self.assertTrue(result['exact_match'])
        self.assertEqual(result['mode'], 'physical_rx_assisted_alignment')
        with self.assertRaises(ValueError):
            read_bits(paths[0])

    def test_corruption_wrong_model_and_truncation_rejected(self):
        source = b'abc'
        identity = bytes(8)
        packet = pack_packet(bytes(6), source, identity, 1, 0, 1)
        for bad in (packet[:-1], packet[:25]+bytes([packet[25] ^ 1])+packet[26:]):
            with self.assertRaises(ValueError):
                unpack_packet(bad, identity)
        with self.assertRaises(ValueError):
            unpack_packet(packet, b'12345678')

    def test_missing_duplicate_rejected_and_empty_inputs(self):
        _, paths = self.prepare()
        for name, inputs in (('missing', paths[:1]), ('duplicate', paths+[paths[0]])):
            result = receive(self.model_path, inputs, self.out/name, ideal=True)
            self.assertFalse(result['complete'])
            self.assertFalse((self.out/name/'reconstructed.bin').exists())
        self.source.write_bytes(b'')
        with self.assertRaises(ValueError):
            prepare(self.model_path, self.source, self.out/'empty')

    def test_synchronization_failure_preserved_as_failure(self):
        _, paths = self.prepare()
        bad = self.out/'rejected.mat'
        data = loadmat(paths[0], simplify_cells=True)
        savemat(bad, dict(status='error', tx_bits=data['tx_bits'], rx_aligned=[], sps=10))
        result = receive(self.model_path, [bad], self.out/'rejected_result')
        self.assertEqual(result['attempts'], 1)
        self.assertEqual(result['accepted'], 0)
        self.assertFalse(result['complete'])
        self.assertFalse((self.out/'rejected_result/reconstructed.bin').exists())


if __name__ == '__main__':
    unittest.main()
