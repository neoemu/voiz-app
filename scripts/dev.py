#!/usr/bin/env python3
"""Local Voiz development. Never installs or publishes the official application."""
from __future__ import annotations
import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / 'build'
DEV_ID = 'com.rmb.voiz.dev'
DESTINATION = Path('/Applications/Voiz Dev.app')
# Until 12/10/2026 the Dev lived here. Any second Voiz Dev that macOS knows about can be the copy
# it reopens by bundle ID (System Settings' "Quit & Reopen" did exactly that with an old build).
LEGACY_DESTINATION = Path.home() / 'Applications' / 'Voiz Dev.app'
LSREGISTER = Path('/System/Library/Frameworks/CoreServices.framework/Frameworks/'
                  'LaunchServices.framework/Support/lsregister')
DEV_TEAM = os.environ.get('VOIZ_DEV_TEAM', '')

class DevError(RuntimeError):
    pass

def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)

def captured(args):
    return run(args, capture_output=True, text=True).stdout.strip()

@contextlib.contextmanager
def development_lock():
    folder = Path.home() / 'Library' / 'Caches' / 'VoizDevelopment'
    folder.mkdir(parents=True, exist_ok=True)
    with (folder / 'session.lock').open('a+') as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise DevError('Outra sessão está usando o fluxo Dev. Aguarde essa operação terminar.')
        handle.seek(0)
        handle.truncate()
        handle.write(str(ROOT))
        handle.flush()
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)

def control(action):
    source = ROOT / 'scripts' / 'dev_app_control.swift'
    binary = BUILD / 'DeveloperTools' / 'VoizDevControl'
    if not binary.exists() or source.stat().st_mtime > binary.stat().st_mtime:
        binary.parent.mkdir(parents=True, exist_ok=True)
        run(['xcrun', 'swiftc', source, '-o', binary])
    return captured([binary, action])

def running_apps():
    return json.loads(control('status'))

def assert_not_running():
    if running_apps():
        raise DevError('Voiz Dev está aberto. Encerre-o com make dev-stop e execute make dev novamente. Nenhum app foi substituído.')

def validate_info(info):
    if info.get('CFBundleIdentifier') != DEV_ID:
        raise DevError('Bundle não é com.rmb.voiz.dev; instalação recusada.')
    if info.get('VoizUpdatesEnabled') != 'NO':
        raise DevError('O atualizador deve estar desativado no Dev; instalação recusada.')
    if info.get('CFBundleExecutable') != 'Voiz Dev':
        raise DevError('Nome do executável Dev inesperado; instalação recusada.')

def verify_bundle(bundle):
    info = plistlib.loads((bundle / 'Contents' / 'Info.plist').read_bytes())
    validate_info(info)
    run(['codesign', '--verify', '--deep', '--strict', bundle], capture_output=True)
    signature = run(['codesign', '-dv', '--verbose=4', bundle], capture_output=True, text=True).stderr.splitlines()
    # A Team ID keeps keychain partitions stable across builds; a team-less cert re-prompts every build.
    if not any(line.startswith('Authority=Apple Development:') for line in signature) \
            or f'TeamIdentifier={DEV_TEAM}' not in signature:
        raise DevError(f'A assinatura precisa usar a identidade Apple Development do time {DEV_TEAM}.')
    entitlements = run(['codesign', '-d', '--entitlements', '-', '--xml', bundle], capture_output=True).stdout
    if plistlib.loads(entitlements).get('com.apple.security.app-sandbox') is not True:
        raise DevError('Sandbox ausente; isolamento dos dados não está garantido.')
    return info

def build_metadata():
    branch = captured(['git', '-C', ROOT, 'branch', '--show-current']) or 'detached'
    commit = captured(['git', '-C', ROOT, 'rev-parse', '--short=12', 'HEAD'])
    dirty = bool(captured(['git', '-C', ROOT, 'status', '--porcelain', '--untracked-files=normal']))
    return [f'VOIZ_BUILD_BRANCH={branch}', f'VOIZ_BUILD_COMMIT={commit}',
            f'VOIZ_BUILD_DIRTY={"YES" if dirty else "NO"}', f'VOIZ_BUILD_SOURCE_PATH={ROOT}']

def xcode(action, only):
    if not DEV_TEAM or not DEV_TEAM.isalnum():
        raise DevError('Defina VOIZ_DEV_TEAM com sua equipe Apple Development antes de compilar/testar.')
    BUILD.mkdir(exist_ok=True)
    log_dir = BUILD / 'DevelopmentLogs'
    log_dir.mkdir(exist_ok=True)
    is_test = action == 'test'
    args = ['xcodebuild', '-project', ROOT / 'voiz.xcodeproj',
            '-scheme', 'Voiz Tests' if is_test else 'Voiz Dev',
            '-configuration', 'Debug' if is_test else 'Development',
            '-derivedDataPath', BUILD,
            '-destination', f'platform=macOS,arch={platform.machine()}',
            'ONLY_ACTIVE_ARCH=YES', f'VOIZ_DEVELOPMENT_TEAM={DEV_TEAM}',
            f'DEVELOPMENT_TEAM={DEV_TEAM}', 'CODE_SIGN_IDENTITY=Apple Development']
    if is_test:
        args.extend(f'-only-testing:{suite}' for suite in only)
        # The dedicated scheme builds only the hostless test bundle. It never launches Voiz.
    else:
        args.extend(build_metadata())
    args.append('test' if is_test else 'build')
    log = log_dir / ('tests.log' if is_test else 'build.log')
    print(f'{"Testando" if is_test else "Compilando Voiz Dev"}: {ROOT}', flush=True)
    print(f'Log: {log}', flush=True)
    with log.open('w') as output:
        result = subprocess.run([str(a) for a in args], stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        lines = log.read_text(errors='replace').splitlines()
        errors = [line for line in lines if 'error:' in line or 'failed' in line.lower()]
        print('\n'.join((errors or lines[-30:])[-25:]), file=sys.stderr)
        raise DevError(f'Falha no {"teste" if is_test else "build"}. Veja {log}. Instalações preservadas.')
    if is_test:
        summaries = [line for line in log.read_text(errors='replace').splitlines()
                     if 'Test run with' in line or '** TEST' in line]
        print('\n'.join(summaries))
        return None
    app = BUILD / 'Build' / 'Products' / 'Development' / 'Voiz Dev.app'
    verify_bundle(app)
    # Xcode registers its products; the build copy must never be a launch candidate.
    launch_services('-u', app)
    print(f'Build verificado: {app}')
    return app

def launch_services(flag, bundle):
    """Best effort: a stale registration only changes which copy macOS picks by bundle ID."""
    with contextlib.suppress(OSError):
        subprocess.run([str(LSREGISTER), flag, str(bundle)], capture_output=True)

def retire_legacy_install(legacy=LEGACY_DESTINATION):
    """Remove the pre-/Applications Dev copy once the verified install exists."""
    if legacy.is_symlink() or not legacy.exists():
        return
    validate_info(plistlib.loads((legacy / 'Contents' / 'Info.plist').read_bytes()))
    assert_not_running()
    launch_services('-u', legacy)
    shutil.rmtree(legacy)
    print(f'Cópia antiga removida: {legacy}')

def install_bundle(source, destination=DESTINATION):
    """Stage and verify before replacing; restore the old Dev if final verification fails."""
    if destination.name != 'Voiz Dev.app' or destination.is_symlink():
        raise DevError('Destino Dev inválido. Nenhum app foi substituído.')
    if destination.exists():
        validate_info(plistlib.loads((destination / 'Contents' / 'Info.plist').read_bytes()))
    verify_bundle(source)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix='.voiz-dev-install-', dir=destination.parent))
    staging = temporary / 'Voiz Dev.app'
    backup = temporary / 'previous.app'
    had_previous = destination.exists()
    cleanup = False
    try:
        run(['ditto', '--noqtn', source, staging])
        verify_bundle(staging)
        # Recheck after copying: another launch may have happened during the build/copy.
        assert_not_running()
        if had_previous:
            destination.rename(backup)
        staging.rename(destination)
        verify_bundle(destination)
        cleanup = True
    except BaseException as error:
        try:
            # Inspect the filesystem rather than a flag: an interruption may arrive immediately
            # after a successful rename, before Python can record its result.
            if backup.exists():
                if destination.exists():
                    destination.rename(temporary / 'failed.app')
                backup.rename(destination)
            elif not had_previous and destination.exists():
                destination.rename(temporary / 'failed.app')
            cleanup = True
        except BaseException as rollback_error:
            raise DevError(f'Instalação interrompida; recuperação manual em {temporary}. '
                           'A cópia anterior foi preservada. Não apague essa pasta.') from rollback_error
        raise error
    finally:
        # A failed rollback must NEVER delete the user's last verified Dev bundle.
        if cleanup:
            shutil.rmtree(temporary)
    print(f'Voiz Dev instalado: {destination}')

def status():
    apps = running_apps()
    print(f'Checkout desta sessão: {ROOT}')
    if DESTINATION.exists():
        info = plistlib.loads((DESTINATION / 'Contents' / 'Info.plist').read_bytes())
        validate_info(info)
        print(f'Instalado: {DESTINATION}')
        print(f'Origem: {info.get("VoizBuildSourcePath", "desconhecida")}')
        dirty = ' (alterações locais)' if info.get('VoizBuildDirty') == 'YES' else ''
        print(f'Branch/build: {info.get("VoizBuildBranch", "?")} · {info.get("VoizBuildCommit", "?")}{dirty}')
    else:
        print('Voiz Dev ainda não instalado. Use make dev.')
    if LEGACY_DESTINATION.exists():
        print(f'Cópia antiga em {LEGACY_DESTINATION}: o próximo make dev a remove.')
    for app in apps:
        print(f'Em execução: PID {app["pid"]} · {app["path"]}')
    if not apps:
        print('Voiz Dev está fechado.')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['run', 'build', 'open', 'status', 'stop', 'test'])
    parser.add_argument('--only', action='append', default=[])
    args = parser.parse_args()
    if sys.platform != 'darwin':
        raise DevError('Este fluxo requer macOS e Xcode.')
    if not (ROOT / 'Config' / 'AppInfo.plist').exists() or not (ROOT / 'scripts' / 'distribute.sh').exists():
        raise DevError('Checkout desatualizado: integre a base atual de distribuição antes de usar Dev.')
    with development_lock():
        if args.action == 'status':
            status()
        elif args.action == 'stop':
            print(control('stop'))
        elif args.action == 'open':
            verify_bundle(DESTINATION)
            status()
            run(['open', DESTINATION])
        elif args.action == 'test':
            only = args.only or os.environ.get('TEST_ONLY', '').split()
            xcode('test', only)
        else:
            if args.action == 'run':
                assert_not_running()
            app = xcode('build', [])
            if args.action == 'run':
                install_bundle(app)
                launch_services('-f', DESTINATION)
                retire_legacy_install()
                run(['open', DESTINATION])

if __name__ == '__main__':
    try:
        main()
    except (DevError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'Erro: {error}', file=sys.stderr)
        sys.exit(1)
