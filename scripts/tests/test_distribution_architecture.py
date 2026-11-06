"""Exercise the platform gate with real disposable Mach-O executables, without signing or launching them."""
import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('verify_distribution', ROOT / 'scripts/verify_distribution.py')
distribution = importlib.util.module_from_spec(spec)
spec.loader.exec_module(distribution)


@unittest.skipUnless(sys.platform == 'darwin', 'Requires macOS Mach-O tools')
class DistributionArchitectureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='voiz-architecture-test-')
        cls.addClassCleanup(cls.temp.cleanup)
        cls.root = Path(cls.temp.name)
        source = cls.root / 'main.c'
        source.write_text('int main(void) { return 0; }\n')
        for architecture in ['arm64', 'x86_64']:
            subprocess.run(['xcrun', 'clang', '-arch', architecture, str(source),
                            '-o', str(cls.root / architecture)], check=True, capture_output=True)
        subprocess.run(['lipo', '-create', str(cls.root / 'arm64'), str(cls.root / 'x86_64'),
                        '-output', str(cls.root / 'universal')], check=True, capture_output=True)

    def bundle(self, architecture):
        directory = self.root / (architecture + '.app')
        executable = directory / 'Contents/MacOS/fixture'
        executable.parent.mkdir(parents=True)
        shutil.copy2(self.root / architecture, executable)
        (directory / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'fixture'}))
        return directory

    def test_apple_silicon_bundle_is_accepted(self):
        distribution.verify_application_architecture(self.bundle('arm64'))

    def test_intel_bundle_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'somente arm64'):
            distribution.verify_application_architecture(self.bundle('x86_64'))

    def test_old_universal_bundle_is_rejected(self):
        # Keeping an ARM slice alongside Intel is insufficient for the new release policy.
        with self.assertRaisesRegex(ValueError, 'somente arm64'):
            distribution.verify_application_architecture(self.bundle('universal'))


if __name__ == '__main__':
    unittest.main()
