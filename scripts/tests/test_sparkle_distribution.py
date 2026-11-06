"""Check the release verifier with ephemeral Ed25519 keys and disposable bytes.

No signing identity, Keychain, app bundle, license API or network is used.
The optional interoperability case calls the already-resolved Sparkle 2.10 tool
with an ephemeral seed on stdin; all other cases run without Sparkle artifacts.
"""
import base64
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

ROOT = Path(__file__).resolve().parents[2]
SIGN_UPDATE = ROOT / 'build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update'


@unittest.skipUnless(sys.platform == 'darwin', 'Release verifier uses macOS CryptoKit')
class SparkleDistributionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compiler_temp = tempfile.TemporaryDirectory(prefix='voiz-sparkle-verifier-')
        cls.verifier = Path(cls.compiler_temp.name) / 'verify-sparkle'
        subprocess.run(['swiftc', str(ROOT / 'scripts/verify_sparkle.swift'), '-o', str(cls.verifier)],
                       check=True, capture_output=True, text=True)

    @classmethod
    def tearDownClass(cls):
        cls.compiler_temp.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='voiz-sparkle-fixture-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / 'Voiz-1.13.0-21-macOS.zip'
        with zipfile.ZipFile(self.archive, 'w') as fixture:
            fixture.writestr('synthetic.txt', 'Disposable update validation; no app or user data.')
        self.feed = self.root / 'appcast.xml'
        self.info = self.root / 'Info.plist'
        self.key = Ed25519PrivateKey.generate()
        self.write_info(self.key)
        self.write_feed()

    def write_info(self, key):
        self.info.write_bytes(plistlib.dumps({
            'SUPublicEDKey': base64.b64encode(key.public_key().public_bytes_raw()).decode(),
            'CFBundleVersion': '21', 'CFBundleShortVersionString': '1.13.0',
        }))

    def xml(self, **overrides):
        values = {
            'build': '21', 'version': '1.13.0',
            'url': 'https://voiz.dev/updates/' + self.archive.name,
            'signature': base64.b64encode(self.key.sign(self.archive.read_bytes())).decode(),
            'length': str(self.archive.stat().st_size),
        }
        values.update(overrides)
        return ('''<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
<channel><title>Synthetic Voiz update</title><item>
<sparkle:version>{build}</sparkle:version>
<sparkle:shortVersionString>{version}</sparkle:shortVersionString>
<enclosure url="{url}" length="{length}" sparkle:edSignature="{signature}" />
</item></channel></rss>
'''.format(**values)).encode()

    def write_feed(self, **overrides):
        content = self.xml(**overrides)
        signature = base64.b64encode(self.key.sign(content)).decode()
        self.feed.write_bytes(content + (
            f'<!-- sparkle-signatures:\nedSignature: {signature}\nlength: {len(content)}\n-->\n'
        ).encode())

    def verify(self, error=None, local_test=False):
        options = ['--local-test'] if local_test else []
        result = subprocess.run([str(self.verifier), *options, str(self.feed), str(self.archive), str(self.info)],
                                capture_output=True, text=True)
        if error is None:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, result.stderr)

    def test_valid_package_and_feed(self):
        self.verify()

    def test_same_length_archive_tampering_is_rejected(self):
        payload = bytearray(self.archive.read_bytes())
        payload[40] ^= 1
        self.archive.write_bytes(payload)
        self.verify('Assinatura do pacote inválida')

    def test_same_length_feed_tampering_is_rejected(self):
        self.feed.write_bytes(self.feed.read_bytes().replace(b'Synthetic', b'Altered__'))
        self.verify('Assinatura do appcast inválida')

    def test_another_public_key_is_rejected(self):
        self.write_info(Ed25519PrivateKey.generate())
        self.verify('Assinatura do appcast inválida')

    def test_missing_or_truncated_feed_signature_is_rejected(self):
        for payload in [self.xml(), self.feed.read_bytes()[:-3]]:
            with self.subTest(payload_length=len(payload)):
                self.feed.write_bytes(payload)
                self.verify('assinatura Sparkle')

    def test_trailing_unsigned_data_is_rejected(self):
        self.feed.write_bytes(self.feed.read_bytes() + b'<!-- extra -->\n')
        self.verify('Bloco de assinatura Sparkle inválido')

    def test_signed_but_incorrect_release_metadata_is_rejected(self):
        cases = [
            ({'build': '20'}, 'Build incorreto'),
            ({'version': '1.12.2'}, 'Versão incorreta'),
            ({'url': 'https://example.invalid/update.zip'}, 'URL de download incorreta'),
            ({'length': '1'}, 'Tamanho do pacote incorreto'),
            ({'signature': base64.b64encode(bytes(64)).decode()}, 'Assinatura do pacote inválida'),
        ]
        for overrides, error in cases:
            with self.subTest(overrides=overrides):
                self.write_feed(**overrides)
                self.verify(error)

    def test_loopback_requires_explicit_local_test_mode(self):
        self.write_feed(url='http://localhost:8765/' + self.archive.name)
        self.verify('URL de download incorreta')
        self.verify(local_test=True)

    def test_local_test_refuses_other_origins_credentials_and_query(self):
        urls = [
            'https://voiz.dev/updates/' + self.archive.name,
            'http://127.0.0.1:8765/' + self.archive.name,
            'http://localhost:8766/' + self.archive.name,
            'http://localhost.example.invalid:8765/' + self.archive.name,
            'http://user:password@localhost:8765/' + self.archive.name,
            'http://localhost:8765/' + self.archive.name + '?secret=fixture',
        ]
        for url in urls:
            with self.subTest(url=url):
                self.write_feed(url=url)
                self.verify('URL de download incorreta', local_test=True)

    @unittest.skipUnless(SIGN_UPDATE.is_file(), 'Resolve Sparkle packages for tool interoperability')
    def test_sparkle_tool_signatures_are_accepted_and_tampering_is_rejected(self):
        # Sparkle supports a 32-byte seed via stdin. Never call its Keychain default.
        seed_input = base64.b64encode(self.key.private_bytes_raw()).decode() + '\n'
        signed_archive = subprocess.run(
            [str(SIGN_UPDATE), '--ed-key-file', '-', '-p', str(self.archive)], input=seed_input,
            check=True, capture_output=True, text=True,
        )
        self.feed.write_bytes(self.xml(signature=signed_archive.stdout.strip()))
        subprocess.run([str(SIGN_UPDATE), '--ed-key-file', '-', str(self.feed)], input=seed_input,
                       check=True, capture_output=True, text=True)
        self.verify()
        self.feed.write_bytes(self.feed.read_bytes().replace(b'Synthetic', b'Altered__'))
        self.verify('Assinatura do appcast inválida')


if __name__ == '__main__':
    unittest.main()
