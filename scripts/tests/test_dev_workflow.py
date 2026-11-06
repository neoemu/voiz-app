"""Failure-path tests for the local installer, using only temporary fake bundles."""
import importlib.util
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('voiz_dev', Path(__file__).parents[1] / 'dev.py')
dev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dev)

class DevelopmentInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / 'source' / 'Voiz Dev.app'
        self.destination = self.root / 'Applications' / 'Voiz Dev.app'
        self.bundle(self.source, 'new')
        self.bundle(self.destination, 'old')

    def tearDown(self):
        self.temp.cleanup()

    def bundle(self, path, contents, **overrides):
        (path / 'Contents').mkdir(parents=True, exist_ok=True)
        info = {'CFBundleIdentifier': dev.DEV_ID, 'VoizUpdatesEnabled': 'NO', 'CFBundleExecutable': 'Voiz Dev'}
        info.update(overrides)
        (path / 'Contents' / 'Info.plist').write_bytes(plistlib.dumps(info))
        (path / 'payload.txt').write_text(contents)

    @staticmethod
    def copy_command(args, **kwargs):
        assert args[:2] == ['ditto', '--noqtn']
        shutil.copytree(args[2], args[3])

    def install(self, verify=lambda path: None, is_running=False):
        with patch.object(dev, 'verify_bundle', side_effect=verify), \
             patch.object(dev, 'run', side_effect=self.copy_command), \
             patch.object(dev, 'running_apps', return_value=[{'pid': 1}] if is_running else []):
            dev.install_bundle(self.source, self.destination)

    def test_official_identity_is_rejected(self):
        for updates in ['NO', 'YES']:
            with self.assertRaises(dev.DevError):
                dev.validate_info({'CFBundleIdentifier': 'com.rmb.voiz', 'VoizUpdatesEnabled': updates, 'CFBundleExecutable': 'Voiz Dev'})

    def test_enabled_updater_is_rejected(self):
        with self.assertRaises(dev.DevError):
            dev.validate_info({'CFBundleIdentifier': dev.DEV_ID, 'VoizUpdatesEnabled': 'YES', 'CFBundleExecutable': 'Voiz Dev'})

    def test_does_not_replace_unknown_existing_app(self):
        self.bundle(self.destination, 'official', CFBundleIdentifier='com.rmb.voiz')
        with self.assertRaises(dev.DevError):
            self.install()
        self.assertEqual((self.destination / 'payload.txt').read_text(), 'official')

    def test_running_app_preserves_existing_bundle(self):
        with self.assertRaises(dev.DevError):
            self.install(is_running=True)
        self.assertEqual((self.destination / 'payload.txt').read_text(), 'old')

    def test_invalid_staging_preserves_existing_bundle(self):
        def verification(path):
            if path != self.source:
                raise dev.DevError('invalid staged signature')
        with self.assertRaises(dev.DevError):
            self.install(verify=verification)
        self.assertEqual((self.destination / 'payload.txt').read_text(), 'old')

    def test_final_verification_failure_rolls_back(self):
        def verification(path):
            if path == self.destination:
                raise dev.DevError('invalid installed signature')
        with self.assertRaises(dev.DevError):
            self.install(verify=verification)
        self.assertEqual((self.destination / 'payload.txt').read_text(), 'old')
        self.assertEqual(list(self.destination.parent.iterdir()), [self.destination])

    def test_failed_rollback_keeps_recovery_bundle(self):
        original_rename = Path.rename
        def verification(path):
            if path == self.destination:
                raise dev.DevError('final signature invalid')
        def rename(path, destination):
            if path.name == 'previous.app':
                raise OSError('simulated rollback failure')
            return original_rename(path, destination)
        with patch.object(Path, 'rename', new=rename):
            with self.assertRaisesRegex(dev.DevError, 'recuperação manual'):
                self.install(verify=verification)
        backups = list(self.destination.parent.glob('.voiz-dev-install-*/previous.app'))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / 'payload.txt').read_text(), 'old')

    def test_interrupt_after_backup_rename_restores_old_bundle(self):
        original_rename = Path.rename
        def rename(path, destination):
            result = original_rename(path, destination)
            if path == self.destination:
                raise KeyboardInterrupt()
            return result
        with patch.object(Path, 'rename', new=rename):
            with self.assertRaises(KeyboardInterrupt):
                self.install()
        self.assertEqual((self.destination / 'payload.txt').read_text(), 'old')

    def test_success_replaces_only_dev(self):
        official = self.root / 'Applications' / 'voiz.app'
        self.bundle(official, 'official', CFBundleIdentifier='com.rmb.voiz')
        self.install()
        self.assertEqual((self.destination / 'payload.txt').read_text(), 'new')
        self.assertEqual((official / 'payload.txt').read_text(), 'official')

    def test_installs_in_system_applications_beside_official(self):
        self.assertEqual(dev.DESTINATION, Path('/Applications/Voiz Dev.app'))
        self.assertNotEqual(dev.DESTINATION.name.lower(), 'voiz.app')

    def retire(self, legacy, is_running=False):
        with patch.object(dev, 'launch_services') as registry, \
             patch.object(dev, 'running_apps', return_value=[{'pid': 1}] if is_running else []):
            dev.retire_legacy_install(legacy)
        return registry

    def test_retires_legacy_dev_copy(self):
        registry = self.retire(self.destination)
        self.assertFalse(self.destination.exists())
        registry.assert_called_once_with('-u', self.destination)

    def test_legacy_retirement_refuses_official_bundle(self):
        self.bundle(self.destination, 'official', CFBundleIdentifier='com.rmb.voiz')
        with self.assertRaises(dev.DevError):
            self.retire(self.destination)
        self.assertEqual((self.destination / 'payload.txt').read_text(), 'official')

    def test_legacy_retirement_waits_for_running_dev(self):
        with self.assertRaises(dev.DevError):
            self.retire(self.destination, is_running=True)
        self.assertEqual((self.destination / 'payload.txt').read_text(), 'old')

    def test_missing_launch_services_tool_does_not_abort(self):
        with patch.object(dev.subprocess, 'run', side_effect=FileNotFoundError('lsregister')):
            dev.launch_services('-u', self.destination)

    def test_symlink_destination_is_rejected(self):
        linked = self.root / 'link' / 'Voiz Dev.app'
        linked.parent.mkdir()
        linked.symlink_to(self.destination)
        with self.assertRaises(dev.DevError):
            dev.install_bundle(self.source, linked)
        self.assertEqual((self.destination / 'payload.txt').read_text(), 'old')

if __name__ == '__main__':
    unittest.main()
