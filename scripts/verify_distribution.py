#!/usr/bin/env python3
"""Recusa bundles que não atendem à assinatura e configuração do canal público."""
import base64
import pathlib
import plistlib
import re
import subprocess
import sys


def verify_application_architecture(app: pathlib.Path):
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable or pathlib.Path(executable).name != executable:
        raise ValueError("Executável do app inválido")
    binary = app / "Contents/MacOS" / executable
    architectures = subprocess.run(["lipo", "-archs", str(binary)], check=True,
                                   capture_output=True, text=True).stdout.split()
    if architectures != ["arm64"]:
        raise ValueError("O app de distribuição deve conter somente arm64 (Apple Silicon)")


def verify(app: pathlib.Path, team: str):
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("Team ID inválido")
    verify_application_architecture(app)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    framework = app / "Contents/Frameworks/Sparkle.framework"
    components = [app, framework]
    components.extend(framework / "Versions/B" / item for item in [
        "XPCServices/Installer.xpc", "XPCServices/Downloader.xpc", "Autoupdate", "Updater.app"
    ])
    for component in components:
        subprocess.run(["codesign", "--verify", "--strict", "--verbose=2", str(component)], check=True)
        signature = subprocess.run(["codesign", "-dv", "--verbose=4", str(component)],
                                   check=True, capture_output=True, text=True).stderr
        for required in ["Authority=Developer ID Application:", f"TeamIdentifier={team}", "Timestamp=", "runtime"]:
            if required not in signature:
                raise ValueError(f"Assinatura de distribuição incompleta em {component.name}: falta {required}")
        entitlement_data = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(component)],
                                          check=True, capture_output=True).stdout
        entitlements = plistlib.loads(entitlement_data) if entitlement_data.strip() else {}
        if entitlements.get("com.apple.security.get-task-allow"):
            raise ValueError(f"Entitlement de depuração em {component.name}")
        if component == app and entitlements.get("com.apple.security.cs.disable-library-validation"):
            raise ValueError("Validação de bibliotecas desabilitada no app de distribuição")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    with pathlib.Path("Config/AppInfo.plist").open("rb") as stream:
        expected = plistlib.load(stream)
    for key in ["SUFeedURL", "SUPublicEDKey", "SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction", "SUEnableInstallerLauncherService"]:
        if info.get(key) != expected[key]:
            raise ValueError(f"Configuração de atualização incorreta: {key}")
    if info.get("VoizUpdatesEnabled") != "YES":
        raise ValueError("Atualizações públicas não habilitadas")
    if len(base64.b64decode(info["SUPublicEDKey"], validate=True)) != 32:
        raise ValueError("Chave pública inválida")
    for key in ["CFBundleVersion", "CFBundleShortVersionString"]:
        if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", info.get(key, "")):
            raise ValueError(f"Versão inválida: {key}")
    if list(app.rglob("*Codex*")) or (app / "Contents/Helpers/codex").exists():
        raise ValueError("Componente Codex ainda presente no bundle")


if __name__ == "__main__":
    try:
        verify(pathlib.Path(sys.argv[1]), sys.argv[2])
    except (ValueError, OSError, subprocess.CalledProcessError, IndexError) as error:
        sys.exit(f"Distribuição bloqueada: {error}")
    print("Apple Silicon, assinatura Developer ID, helpers e canal de atualizações verificados.")
