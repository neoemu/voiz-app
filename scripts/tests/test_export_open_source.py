import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('export_open_source', Path(__file__).parents[1] / 'export_open_source.py')
exporter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(exporter)


class PrivateExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'source'
        self.root.mkdir()
        (self.root / 'README.md').write_text('Local app\n')
        self.paths = [{'source': 'README.md', 'destination': 'README.md'}]

    def approved(self):
        manifest = exporter.prepare(self.root, self.paths)
        manifest['reviewed'] = True
        return manifest

    def test_copies_only_pinned_files_and_excludes_history(self):
        (self.root / '.git').mkdir()
        (self.root / '.git' / 'secret').write_text('excluded')
        (self.root / 'unlisted.txt').write_text('excluded')
        target = Path(self.temp.name) / 'candidate'
        self.assertEqual(exporter.export(self.root, self.approved(), target), 1)
        self.assertEqual([p.name for p in target.iterdir()], ['README.md'])
        self.assertEqual((target / 'README.md').read_text(), 'Local app\n')

    def test_review_required(self):
        with self.assertRaises(exporter.ExportError):
            exporter.export(self.root, exporter.prepare(self.root, self.paths), Path(self.temp.name) / 'out')

    def test_changed_bytes_refuse_without_creating_destination(self):
        manifest = self.approved()
        (self.root / 'README.md').write_text('changed')
        target = Path(self.temp.name) / 'out'
        with self.assertRaises(exporter.ExportError):
            exporter.export(self.root, manifest, target)
        self.assertFalse(target.exists())

    def test_existing_destination_is_preserved(self):
        target = Path(self.temp.name) / 'out'
        target.mkdir()
        (target / 'keep').write_text('keep')
        with self.assertRaises(exporter.ExportError):
            exporter.export(self.root, self.approved(), target)
        self.assertEqual((target / 'keep').read_text(), 'keep')

    def test_traversal_and_absolute_rejected(self):
        for value in ['../README.md', '/tmp/README.md', './README.md', 'voiz//x.swift', 'voiz/../x.swift', 'voiz\\x.swift']:
            with self.subTest(value=value), self.assertRaises(exporter.ExportError):
                exporter.allowed_destination(value)

    def test_operational_and_personal_formats_rejected(self):
        for value in ['.git/config', 'Config/distribution.env', 'service/main.swift', 'voiz/recordings/a.swift', 'voiz/a.m4a', 'voiz/Services/Account/client.swift', 'scripts/deploy_licensing.py', 'docs/tracking.md']:
            with self.subTest(value=value), self.assertRaises(exporter.ExportError):
                exporter.allowed_destination(value)

    def test_symlink_file_and_directory_rejected(self):
        real = self.root / 'real'
        real.mkdir()
        (real / 'source.swift').write_text('struct Example {}')
        (self.root / 'voiz').symlink_to(real, target_is_directory=True)
        with self.assertRaises(exporter.ExportError):
            exporter.read_source(self.root, 'voiz/source.swift', 'voiz/source.swift')
        (self.root / 'README.md').unlink()
        (self.root / 'README.md').symlink_to(real / 'source.swift')
        with self.assertRaises(exporter.ExportError):
            exporter.prepare(self.root, self.paths)

    def test_case_insensitive_collision_rejected(self):
        (self.root / 'voiz').mkdir()
        (self.root / 'voiz' / 'A.swift').write_text('struct Example {}')
        paths = [{'source': f'voiz/{name}.swift', 'destination': f'voiz/{name}.swift'} for name in ['A', 'a']]
        with self.assertRaises(exporter.ExportError):
            exporter.prepare(self.root, paths)

    def test_overlay_cannot_read_arbitrary_file(self):
        (self.root / 'secret.txt').write_text('private')
        with self.assertRaises(exporter.ExportError):
            exporter.read_source(self.root, 'secret.txt', 'README.md')
        overlay = self.root / 'migration/public'
        overlay.mkdir(parents=True)
        (overlay / 'README.md').write_text('Reviewed public docs')
        data, _ = exporter.read_source(self.root, 'migration/public/README.md', 'README.md')
        self.assertEqual(data, b'Reviewed public docs')

    def test_explicit_seam_mapping_materializes_canonical_source(self):
        source = 'voiz/Services/NotionCredentialsStore.swift'
        destination = 'voizTests/Meeting/NotionSeam/NotionCredentialsStore.swift'
        path = self.root / source
        path.parent.mkdir(parents=True)
        path.write_text('struct SyntheticStore {}')
        self.paths = [{'source': source, 'destination': destination}]
        target = Path(self.temp.name) / 'out'
        exporter.export(self.root, self.approved(), target)
        self.assertFalse((target / destination).is_symlink())
        self.assertEqual((target / destination).read_text(), path.read_text())

    def test_secret_diagnostic_never_contains_matched_value(self):
        fake = 'gh' + 'p_' + 'SYNTHETIC' * 6
        (self.root / 'README.md').write_text(fake)
        with self.assertRaises(exporter.ExportError) as caught:
            exporter.prepare(self.root, self.paths)
        self.assertNotIn(fake, str(caught.exception))
        self.assertIn('github-token', str(caught.exception))

    def test_manifest_cannot_authorize_publication(self):
        manifest = self.approved()
        manifest['publication_authorized'] = True
        with self.assertRaises(exporter.ExportError):
            exporter.validate(self.root, manifest)

    def test_export_inside_source_refused(self):
        with self.assertRaises(exporter.ExportError):
            exporter.export(self.root, self.approved(), self.root / 'candidate')


if __name__ == '__main__':
    unittest.main()
