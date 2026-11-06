#!/usr/bin/env python3
"""Package an already notarized Voiz app; release the DMG only after Apple accepts it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('output', type=Path, help='New installer output directory')
    args = parser.parse_args()
    app, output = args.app.resolve(), args.output.resolve()
    team = os.environ['VOIZ_TEAM_ID']
    identity = os.environ['VOIZ_DEVELOPER_ID']
    profile = os.environ['VOIZ_NOTARY_PROFILE']
    if not identity.startswith('Developer ID Application: '):
        raise ValueError('Developer ID Application required')
    run('python3', ROOT / 'scripts/verify_distribution.py', app, team, cwd=ROOT)
    run('xcrun', 'stapler', 'validate', app)
    run('spctl', '--assess', '--type', 'execute', '--verbose=2', app)
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    filename = f"Voiz-{info['CFBundleShortVersionString']}-{info['CFBundleVersion']}-macOS.dmg"
    output.mkdir(parents=True, exist_ok=False)
    pending = output / ('pending-' + filename)
    run('uv', 'tool', 'run', '--from', 'dmgbuild==1.6.7', 'dmgbuild',
        '-s', ROOT / 'Config/dmg/settings.py', '-D', f'app={app}', 'Voiz', pending)
    run('codesign', '--sign', identity, '--timestamp', pending)
    run('codesign', '--verify', '--strict', '--verbose=2', pending)
    with (output / 'notarization.json').open('w') as result:
        run('xcrun', 'notarytool', 'submit', pending, '--keychain-profile', profile,
            '--wait', '--output-format', 'json', stdout=result)
    response = json.loads((output / 'notarization.json').read_text())
    run('xcrun', 'notarytool', 'log', response['id'], '--keychain-profile', profile,
        output / 'notarization-log.json')
    if response.get('status') != 'Accepted':
        raise RuntimeError('DMG not accepted by Apple; do not publish pending files.')
    run('xcrun', 'stapler', 'staple', pending)
    run('xcrun', 'stapler', 'validate', pending)
    run('codesign', '--verify', '--strict', '--verbose=2', pending)
    run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=2', pending)
    run('hdiutil', 'verify', pending)
    with tempfile.TemporaryDirectory(prefix='voiz-dmg-check-') as mount:
        run('hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, pending)
        try:
            root = Path(mount)
            assert (root / 'Applications').is_symlink()
            assert os.readlink(root / 'Applications') == '/Applications'
            assert (root / '.DS_Store').is_file()
            run('python3', ROOT / 'scripts/verify_distribution.py', root / app.name, team, cwd=ROOT)
            run('xcrun', 'stapler', 'validate', root / app.name)
        finally:
            run('hdiutil', 'detach', mount)
    final = output / filename
    pending.rename(final)
    digest = hashlib.sha256(final.read_bytes()).hexdigest()
    (output / 'SHA256SUMS').write_text(f'{digest}  {filename}\n')
    (output / 'status.json').write_text(json.dumps({
        'file': filename, 'sha256': digest, 'bytes': final.stat().st_size,
        'notarizationSubmissionID': response['id'], 'notarizationStatus': 'Accepted',
        'ticketStapled': True, 'gatekeeperAccepted': True, 'bundledAppVerified': True,
        'published': False,
    }, indent=2) + '\n')
    print(f'DMG verificado: {final}')


if __name__ == '__main__':
    main()
