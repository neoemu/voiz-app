"""One focused regression for complete and unmodified bundled license notices."""
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("verify_bundle_licenses", ROOT / "scripts/verify_bundle_licenses.py")
licenses = importlib.util.module_from_spec(spec)
spec.loader.exec_module(licenses)


class BundleLicenseTests(unittest.TestCase):
    def test_bundle_license_integrity(self):
        with tempfile.TemporaryDirectory(prefix="voiz-license-test-") as directory:
            app = Path(directory) / "Fixture.app"
            resources = app / "Contents/Resources"
            resources.mkdir(parents=True)
            for name in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
                shutil.copyfile(ROOT / name, resources / name)
            shutil.copytree(ROOT / "ThirdPartyNotices", resources / "ThirdPartyNotices")
            expected_count = 2 + len(list((ROOT / "ThirdPartyNotices").iterdir()))
            self.assertEqual(licenses.verify_bundle_licenses(app), expected_count)

            for relative in [Path("LICENSE"), Path("THIRD_PARTY_NOTICES.md"),
                             *[path.relative_to(ROOT) for path in sorted((ROOT / "ThirdPartyNotices").iterdir())]]:
                bundled = resources / relative
                original = bundled.read_bytes()
                with self.subTest(file=str(relative), failure="missing"):
                    bundled.unlink()
                    with self.assertRaises(ValueError):
                        licenses.verify_bundle_licenses(app)
                with self.subTest(file=str(relative), failure="modified"):
                    bundled.write_bytes(original + b"\nchanged\n")
                    with self.assertRaises(ValueError):
                        licenses.verify_bundle_licenses(app)
                with self.subTest(file=str(relative), failure="external symlink"):
                    bundled.unlink()
                    bundled.symlink_to(ROOT / relative)
                    with self.assertRaises(ValueError):
                        licenses.verify_bundle_licenses(app)
                    bundled.unlink()
                    bundled.write_bytes(original)

            extra = resources / "ThirdPartyNotices/unexpected.txt"
            extra.write_text("synthetic unexpected notice\n")
            with self.assertRaises(ValueError):
                licenses.verify_bundle_licenses(app)
            extra.unlink()
            self.assertEqual(licenses.verify_bundle_licenses(app), expected_count)


if __name__ == "__main__":
    unittest.main()
