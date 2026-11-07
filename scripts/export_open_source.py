#!/usr/bin/env python3
"""Create a local, hash-pinned export from an explicit reviewed file manifest.

No network, Git history, credentials, app data, or production operations are used.
`prepare` consumes a JSON array of {source, destination} relative file paths.
`check` verifies bytes and scans without writing. `export` also requires reviewed=true.
A successful export is a PRIVATE CANDIDATE, never publication approval.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import tempfile


class ExportError(ValueError):
    pass


FORBIDDEN_PARTS = {
    '.git', '.cloudflare', '.wrangler', '.claude', '.codex', '.build',
    'node_modules', 'build', 'DerivedData', 'xcuserdata', '__pycache__',
    'service', 'website', 'recordings', 'sessions', 'backups',
}
FORBIDDEN_EXTENSIONS = {'.pem', '.p12', '.p8', '.key', '.age', '.sqlite', '.db', '.log',
                        '.wav', '.mp3', '.m4a', '.aiff', '.flac', '.zip', '.dmg'}
ROOT_FILES = {'README.md', 'AGENTS.md', 'CONTRIBUTING.md', 'SECURITY.md',
              'THIRD_PARTY_NOTICES.md', 'LICENSE', 'LICENSE-PENDING.md',
              '.gitignore', 'Makefile', 'Package.swift', 'Package.resolved'}
SAFE_SCRIPTS = {'dev.py', 'dev_app_control.swift', 'distribute.sh', 'package_dmg.py',
                'sign_sparkle.sh', 'verify_sparkle.swift', 'verify_distribution.py',
                'export_open_source.py', 'verify_bundle_licenses.py'}
SAFE_SCRIPT_TESTS = {'test_dev_workflow.py', 'test_sparkle_distribution.py',
                    'test_distribution_architecture.py', 'test_export_open_source.py',
                    'test_bundle_licenses.py'}
SAFE_CONFIG = {'AppInfo.plist', 'Development.xcconfig', 'Development.local.xcconfig.example',
               'distribution.env.example', 'ExportOptions.plist', 'TestInfo.plist'}
MATERIALIZED_SEAMS = {
    'voizTests/Meeting/NotionSeam/NotionCredentialsStore.swift': 'voiz/Services/NotionCredentialsStore.swift',
    'voizTests/Meeting/NotionSeam/NotionExportService.swift': 'voiz/Services/NotionExportService.swift',
    'voizTests/Transcription/LanguageSeam/TranscriptionLanguageProbe.swift': 'voiz/Transcription/Language/TranscriptionLanguageProbe.swift',
    'voizTests/Transcription/LanguageSeam/TranscriptionLanguageGuard.swift': 'voiz/Transcription/Language/TranscriptionLanguageGuard.swift',
}
SAFE_DOCS = {'build.md', 'architecture.md', 'data-migration.md', 'privacy.md',
             'distribution.md', 'models.md'}
# Rules never include the matched text in diagnostics. Heuristics are supplementary,
# not proof that arbitrary personal data or novel credential formats are absent.
RULES = {
    'private-key': rb'-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----\s+[A-Za-z0-9+/]{20}',
    'github-token': rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})\b',
    'aws-access-key': rb'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b',
    'openai-key': rb'\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{35,}\b',
    'slack-token': rb'\bxox[baprs]-[A-Za-z0-9-]{30,}\b',
    'personal-checkout-path': rb'/Users/(?:rmb|rodrigo)(?:/|\\)',
    'retired-voiz-api': rb'https://(?:voiz\.dev/api/(?:licensing|sync|ai)|(?:api|sync)\.voiz\.dev)',
}

# Manually inspected test-only sentinel; never contact a provider with it. Exact
# file bytes and rule are pinned, so any edit requires fresh review.
REVIEWED_SYNTHETIC_FIXTURES = {
    ('voizTests/Transcription/TranscriptionLogRedactionTests.swift', 'openai-key'):
        'debd7440bcbab0e4029ad2d9e4036ee3f4a6768406987174b2ff7edf23f96066',
}


def relative(value: object) -> PurePosixPath:
    if not isinstance(value, str) or not value or '\\' in value or '\x00' in value:
        raise ExportError('Invalid relative file path')
    parts = value.split('/')
    if value.startswith('/') or any(p in {'', '.', '..'} for p in parts):
        raise ExportError('Absolute or traversal path rejected')
    if any(any(ord(c) < 32 for c in p) for p in parts):
        raise ExportError('Control character in file path')
    return PurePosixPath(value)


def allowed_destination(value: str) -> PurePosixPath:
    path = relative(value)
    if any(part in FORBIDDEN_PARTS for part in path.parts):
        raise ExportError(f'Forbidden export path: {path}')
    if path.suffix.lower() in FORBIDDEN_EXTENSIONS or '.env' in path.name and path.name != 'distribution.env.example':
        raise ExportError(f'Forbidden export file: {path}')
    if len(path.parts) == 1 and value in ROOT_FILES:
        return path
    if path.parts[0] in {'voiz', 'voizTests'}:
        if any(part in {'Account', 'Licensing'} for part in path.parts):
            raise ExportError(f'Cloud-only source rejected: {path}')
        if path.suffix in {'.swift', '.xcstrings', '.json', '.png', '.plist', '.entitlements'}:
            return path
    if path.parts[0] == 'voiz.xcodeproj' and path.suffix in {'.pbxproj', '.xcscheme', '.xcworkspacedata', '.resolved', '.plist'}:
        return path
    if len(path.parts) == 2 and path.parts[0] == 'Config' and path.name in SAFE_CONFIG:
        return path
    if len(path.parts) == 2 and path.parts[0] == 'scripts' and path.name in SAFE_SCRIPTS:
        return path
    if len(path.parts) == 3 and path.parts[:2] == ('scripts', 'tests') and path.name in SAFE_SCRIPT_TESTS:
        return path
    if len(path.parts) == 2 and path.parts[0] == 'docs' and path.name in SAFE_DOCS:
        return path
    if (len(path.parts) == 3 and path.parts[:2] == ('docs', 'release-notes')
            and re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+\.html', path.name)):
        return path
    if path.parts[0] == 'ThirdPartyNotices' and path.suffix in {'.txt', '.md'}:
        return path
    if value in {'.github/workflows/ci.yml', 'Config/dmg/settings.py'}:
        return path
    raise ExportError(f'Path outside export policy: {path}')


def read_source(root: Path, source: str, destination: str) -> tuple[bytes, int]:
    # An overlay is allowed only when it targets the corresponding approved path.
    src = relative(source)
    dest = allowed_destination(destination)
    if (src != dest and str(src) != 'migration/public/' + str(dest)
            and MATERIALIZED_SEAMS.get(str(dest)) != str(src)):
        raise ExportError(f'Unapproved source mapping: {src}')
    current = root
    for part in src.parts:
        current = current / part
        try:
            mode = current.lstat().st_mode
        except OSError:
            raise ExportError(f'Missing source: {src}') from None
        if stat.S_ISLNK(mode):
            raise ExportError(f'Symlink source rejected: {src}')
    if not stat.S_ISREG(mode):
        raise ExportError(f'Source is not a regular file: {src}')
    if current.stat().st_size > 10 * 1024 * 1024:
        raise ExportError(f'Oversized source requires separate review: {src}')
    return current.read_bytes(), 0o755 if mode & 0o111 else 0o644


def findings(data: bytes, path: str) -> list[dict[str, str]]:
    digest = hashlib.sha256(data).hexdigest()
    return [{'path': path, 'rule': name} for name, pattern in RULES.items()
            if re.search(pattern, data) and REVIEWED_SYNTHETIC_FIXTURES.get((path, name)) != digest]


def prepare(root: Path, paths: list[dict[str, str]]) -> dict:
    entries = []
    for entry in paths:
        source, destination = entry['source'], entry['destination']
        data, mode = read_source(root, source, destination)
        entries.append({'source': source, 'destination': destination,
                        'sha256': hashlib.sha256(data).hexdigest(), 'mode': mode})
    manifest = {'version': 1, 'reviewed': False, 'publication_authorized': False,
                'license_status': ('included-see-LICENSE' if any(e['destination'] == 'LICENSE' for e in entries)
                                   else 'pending-owner-decision'), 'files': entries}
    validate(root, manifest, require_review=False)
    return manifest


def validate(root: Path, manifest: dict, require_review: bool = True) -> list[tuple[str, bytes, int]]:
    if manifest.get('version') != 1 or manifest.get('publication_authorized') is not False:
        raise ExportError('Only private candidate manifests version 1 are accepted')
    if require_review and manifest.get('reviewed') is not True:
        raise ExportError('Review exact file list and bytes, then set reviewed=true in the private manifest')
    entries = manifest.get('files')
    if not isinstance(entries, list) or not entries:
        raise ExportError('Manifest must enumerate files explicitly')
    result, destinations, issues = [], set(), []
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {'source', 'destination', 'sha256', 'mode'}:
            raise ExportError('Invalid manifest entry')
        source, destination = entry['source'], entry['destination']
        path = allowed_destination(destination)
        folded = str(path).casefold()
        if folded in destinations:
            raise ExportError(f'Duplicate destination: {path}')
        # Avoid file/directory collisions even on case-insensitive filesystems.
        if any(folded.startswith(p + '/') or p.startswith(folded + '/') for p in destinations):
            raise ExportError(f'Conflicting destination: {path}')
        destinations.add(folded)
        data, mode = read_source(root, source, destination)
        if hashlib.sha256(data).hexdigest() != entry['sha256'] or mode != entry['mode']:
            raise ExportError(f'Source changed since manifest review: {path}')
        issues.extend(findings(data, str(path)))
        result.append((str(path), data, mode))
    if issues:
        raise ExportError('Content review findings (values redacted): ' + json.dumps(issues))
    return result


def export(root: Path, manifest: dict, destination: Path) -> int:
    root = root.resolve(strict=True)
    files = validate(root, manifest)
    if destination.exists() or destination.is_symlink():
        raise ExportError('Destination must not exist; no existing content is replaced')
    parent = destination.parent.resolve(strict=True)
    resolved = parent / destination.name
    if resolved == root or root in resolved.parents:
        raise ExportError('Export destination must be outside the source checkout')
    staging = Path(tempfile.mkdtemp(prefix='.voiz-private-export-', dir=parent))
    try:
        for name, data, mode in files:
            target = staging / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            target.chmod(mode)
        # Exclusive mkdir reservation prevents replacing a concurrently created target.
        resolved.mkdir(mode=0o700)
        try:
            for item in staging.iterdir():
                item.rename(resolved / item.name)
        except BaseException:
            # Preserve partial output for inspection; never recursively remove a target
            # another process might have touched.
            raise ExportError('Export interrupted; inspect reserved destination before retrying') from None
    finally:
        shutil.rmtree(staging)
    return len(files)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['prepare', 'check', 'export'])
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--paths', type=Path, help='JSON array of explicit source/destination paths (prepare only)')
    parser.add_argument('--destination', type=Path, help='New local directory outside source checkout (export only)')
    args = parser.parse_args()
    try:
        root = args.root.resolve(strict=True)
        if args.command == 'prepare':
            if not args.paths:
                raise ExportError('--paths is required for prepare')
            manifest = prepare(root, json.loads(args.paths.read_text()))
            # Manifest itself stays private and is never added to the exported tree.
            with args.manifest.open('x') as output:
                json.dump(manifest, output, indent=2)
                output.write('\n')
            print(f'Prepared {len(manifest["files"])} paths; manual review pending')
        else:
            manifest = json.loads(args.manifest.read_text())
            if args.command == 'check':
                count = len(validate(root, manifest, require_review=False))
                print(f'Checked {count} exact files; heuristic scan passed; publication remains unauthorized')
            else:
                if not args.destination:
                    raise ExportError('--destination is required for export')
                count = export(root, manifest, args.destination)
                print(f'Exported {count} files into a private candidate; no Git history or remote created')
    except (ExportError, OSError, ValueError, KeyError, TypeError):
        # Errors from parsing/OS may contain data supplied in malformed manifests;
        # only our controlled ExportError diagnostics are safe to show.
        import sys
        exc = sys.exc_info()[1]
        print(str(exc) if isinstance(exc, ExportError) else 'Invalid input or filesystem operation failed', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
