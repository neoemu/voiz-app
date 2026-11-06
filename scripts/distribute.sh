#!/bin/bash
# Gera um pacote oficial para voiz.dev. Não publica no site nem cria tags/commits.
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
# Refuse a known stale checkout before producing a public release.
if git show-ref --verify --quiet refs/remotes/origin/main; then
    if ! git merge-base --is-ancestor origin/main HEAD; then
        echo "Atualize e integre origin/main antes de gerar uma distribuição." >&2
        exit 1
    fi
fi
if [[ -n "$(git diff --name-only --diff-filter=U)" ]]; then
    echo "Resolva os conflitos de merge antes de gerar uma distribuição." >&2
    exit 1
fi
check_only=false
output_dir=""
while (( $# > 0 )); do
    case "$1" in
        --check) check_only=true; shift ;;
        --output-dir)
            [[ $# -ge 2 && -n "$2" ]] || exit 2
            output_dir="$2"; shift 2 ;;
        --help)
            echo "Uso: scripts/distribute.sh [--check] [--output-dir DIRETORIO_NOVO]"
            echo "Configure VOIZ_TEAM_ID, VOIZ_DEVELOPER_ID e VOIZ_NOTARY_PROFILE. Veja docs/distribution.md."
            exit 0 ;;
        *) echo "Argumento desconhecido: $1" >&2; exit 2 ;;
    esac
done

for tool in xcodebuild xcrun codesign security ditto lipo spctl python3 swift shasum uv hdiutil; do
    command -v "$tool" >/dev/null || { echo "Comando obrigatório: $tool" >&2; exit 1; }
done

# Não imprimir credenciais de notarização. Elas ficam no Keychain, fora do repositório.
python3 - <<'PY'
import base64, os, plistlib, re, sys
from urllib.parse import urlsplit
errors=[]
team=os.environ.get('VOIZ_TEAM_ID','')
identity=os.environ.get('VOIZ_DEVELOPER_ID','')
if not re.fullmatch(r'[A-Z0-9]{10}',team): errors.append('VOIZ_TEAM_ID: informe o Team ID da conta Apple Developer.')
if not identity.startswith('Developer ID Application: '): errors.append('VOIZ_DEVELOPER_ID: informe a identidade completa Developer ID Application.')
if not os.environ.get('VOIZ_NOTARY_PROFILE',''): errors.append('VOIZ_NOTARY_PROFILE: informe o perfil de notarização salvo no Keychain.')
with open('Config/AppInfo.plist','rb') as f: info=plistlib.load(f)
feed=urlsplit(info['SUFeedURL'])
if feed.scheme != 'https' or feed.netloc != 'voiz.dev' or feed.path != '/updates/appcast.xml' or feed.query or feed.fragment:
    errors.append('O canal oficial deve ser https://voiz.dev/updates/appcast.xml.')
try:
    if len(base64.b64decode(info['SUPublicEDKey'],validate=True)) != 32: raise ValueError()
except ValueError: errors.append('Chave pública Ed25519 inválida em Config/AppInfo.plist.')
if errors:
    print('\n'.join(errors),file=sys.stderr)
    sys.exit(1)
PY

if ! security find-identity -v -p codesigning | grep -F "\"$VOIZ_DEVELOPER_ID\"" >/dev/null; then
    echo "Certificado e chave privada Developer ID Application indisponíveis neste Mac." >&2
    exit 1
fi
sparkle_bin="$repo_root/build/SourcePackages/artifacts/sparkle/Sparkle/bin"
if [[ ! -x "$sparkle_bin/generate_appcast" ]]; then
    echo "Resolva os pacotes do Xcode primeiro: xcodebuild -resolvePackageDependencies -project voiz.xcodeproj -scheme voiz -clonedSourcePackagesDirPath build/SourcePackages" >&2
    exit 1
fi
expected_key="$(plutil -extract SUPublicEDKey raw Config/AppInfo.plist)"
actual_key="$("$sparkle_bin/generate_keys" --account dev.voiz.updates -p)"
if [[ "$actual_key" != "$expected_key" ]]; then
    echo "A chave de atualizações do Keychain não corresponde à chave pública do app." >&2
    exit 1
fi
xcrun notarytool history --keychain-profile "$VOIZ_NOTARY_PROFILE" --output-format json >/dev/null
if "$check_only"; then
    echo "Pré-requisitos locais verificados. O pacote final ainda precisa ser compilado e notarizado."
    exit 0
fi

if [[ -z "$output_dir" ]]; then
    mkdir -p "$repo_root/build/Distribution"
    output_dir="$(mktemp -d "$repo_root/build/Distribution/release.XXXXXX")"
else
    if [[ -e "$output_dir" ]]; then
        echo "Use um diretório novo; artefatos anteriores não serão sobrescritos." >&2
        exit 1
    fi
    mkdir -p "$output_dir"
    output_dir="$(cd "$output_dir" && pwd)"
fi
archive="$output_dir/Voiz.xcarchive"
export_dir="$output_dir/export"
updates_dir="$output_dir/updates"
mkdir -p "$updates_dir"

xcodebuild -project voiz.xcodeproj -scheme voiz -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$output_dir/DerivedData" \
    -clonedSourcePackagesDirPath "$repo_root/build/SourcePackages" \
    -archivePath "$archive" \
    "CODE_SIGN_IDENTITY=$VOIZ_DEVELOPER_ID" "DEVELOPMENT_TEAM=$VOIZ_TEAM_ID" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS=--timestamp RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION=NO \
    ARCHS=arm64 VOIZ_UPDATES_ENABLED=YES archive

python3 - "$output_dir/ExportOptions.plist" <<'PY'
import os,plistlib,sys
with open(sys.argv[1],'wb') as f:
    plistlib.dump({'method':'developer-id','destination':'export','signingStyle':'manual',
                  'teamID':os.environ['VOIZ_TEAM_ID'],'signingCertificate':os.environ['VOIZ_DEVELOPER_ID']},f)
PY
xcodebuild -exportArchive -archivePath "$archive" \
    -exportPath "$export_dir" -exportOptionsPlist "$output_dir/ExportOptions.plist"
app="$export_dir/voiz.app"
python3 scripts/verify_distribution.py "$app" "$VOIZ_TEAM_ID"

notary_zip="$output_dir/notarization.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$notary_zip"
xcrun notarytool submit "$notary_zip" --keychain-profile "$VOIZ_NOTARY_PROFILE" \
    --wait --output-format json > "$output_dir/notarization.json"
submission_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$output_dir/notarization.json")"
xcrun notarytool log "$submission_id" --keychain-profile "$VOIZ_NOTARY_PROFILE" "$output_dir/notarization-log.json"
python3 - "$output_dir/notarization.json" <<'PY'
import json,sys
with open(sys.argv[1]) as f: result=json.load(f)
if result.get('status') != 'Accepted':
    sys.exit('Notarização não aprovada. Consulte notarization-log.json; nenhum pacote será liberado.')
PY
xcrun stapler staple "$app"
xcrun stapler validate "$app"
python3 scripts/verify_distribution.py "$app" "$VOIZ_TEAM_ID"
spctl --assess --type execute --verbose=2 "$app"

version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
build_number="$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")"
zip_path="$updates_dir/Voiz-${version}-${build_number}-macOS.zip"
release_notes="$repo_root/docs/release-notes/${version}.html"
if [[ -f "$release_notes" ]]; then
    cp "$release_notes" "${zip_path%.zip}.html"
fi
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip_path"
"$sparkle_bin/generate_appcast" --account dev.voiz.updates \
    --download-url-prefix https://voiz.dev/updates/ --link https://voiz.dev \
    --maximum-deltas 0 "$updates_dir"
"$sparkle_bin/sign_update" --account dev.voiz.updates --verify "$updates_dir/appcast.xml"
swift scripts/verify_sparkle.swift "$updates_dir/appcast.xml" "$zip_path" "$app/Contents/Info.plist"
(cd "$updates_dir" && shasum -a 256 "$(basename "$zip_path")" > SHA256SUMS)
python3 scripts/package_dmg.py "$app" "$output_dir/installers"
echo "Pacote verificado: $zip_path"
echo "Publique apenas o DMG e SHA256SUMS de $output_dir/installers em https://voiz.dev/downloads/."
echo "Publique o conteúdo de $updates_dir em https://voiz.dev/updates/ (pacote primeiro, appcast por último)."
echo "Nenhum arquivo foi publicado automaticamente."
