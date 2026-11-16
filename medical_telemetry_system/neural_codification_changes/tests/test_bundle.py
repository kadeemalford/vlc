import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from prepare_bundle import CATALOG, digest, prepare, verify


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.system = self.root/'system'
        for role, name in CATALOG:
            path = self.system/name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((role + '\r\n' + name + '\r\n').encode())
        self.reference = self.root/'reference'

    def test_allowlisted_sources_only_and_exact_bytes(self):
        secret = self.system/'alarm-care-pro-api/.env'
        secret.parent.mkdir(parents=True, exist_ok=True)
        secret.write_text('SYNTHETIC_SECRET=do_not_copy')
        before = {name: digest(self.system/name) for _, name in CATALOG}
        manifest = prepare(self.system, self.reference)
        self.assertEqual(len(manifest['files']), 17)
        self.assertEqual(verify(self.reference, self.system)['files'], 17)
        self.assertEqual(before, {name: digest(self.system/name) for _, name in CATALOG})
        self.assertFalse(list(self.reference.rglob('.env*')))
        self.assertTrue(all(p.suffix == '.reference' for p in self.reference.rglob('*')
                            if p.is_file() and p.name != 'source_manifest.json'))

    def test_refuse_existing_destination(self):
        prepare(self.system, self.reference)
        with self.assertRaises(FileExistsError):
            prepare(self.system, self.reference)

    def test_changed_snapshot_or_source_is_rejected(self):
        manifest = prepare(self.system, self.reference)
        record = manifest['files'][0]
        original = self.system/record['source']
        original.write_bytes(original.read_bytes()+b'changed')
        with self.assertRaisesRegex(ValueError, 'Legacy source differs'):
            verify(self.reference, self.system)
        # Snapshot-only verification remains possible without imported apps.
        self.assertEqual(verify(self.reference)['files'], 17)
        snapshot = self.reference/record['snapshot']
        snapshot.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'Changed or unsafe snapshot'):
            verify(self.reference)

    def test_missing_source_fails_before_creating_destination(self):
        (self.system/CATALOG[0][1]).unlink()
        with self.assertRaisesRegex(ValueError, 'Missing or unsafe source'):
            prepare(self.system, self.reference)
        self.assertFalse(self.reference.exists())

    def test_unsafe_or_incomplete_manifest_rejected(self):
        prepare(self.system, self.reference)
        path = self.reference/'source_manifest.json'
        manifest = json.loads(path.read_text())
        original = json.loads(path.read_text())
        manifest['files'][0]['snapshot'] = '../../outside'
        path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, 'Unexpected or duplicate'):
            verify(self.reference)
        original['files'].pop()
        path.write_text(json.dumps(original))
        with self.assertRaisesRegex(ValueError, 'Incomplete'):
            verify(self.reference)


if __name__ == '__main__':
    unittest.main()
