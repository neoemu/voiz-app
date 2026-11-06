#!/bin/bash
set -euo pipefail

sparkle_framework="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/Sparkle.framework"
identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ -z "$identity" || "$identity" == "-" ]]; then
    echo "error: assinatura válida obrigatória para Sparkle; recusando assinatura ad hoc." >&2
    exit 1
fi

# Xcode assina o framework na cópia; os executáveis internos também precisam da identidade
# configurada. Assinar de dentro para fora preserva as permissões próprias de cada helper.
timestamp=--timestamp=none
if [[ "${EXPANDED_CODE_SIGN_IDENTITY_NAME:-}" == "Developer ID Application:"* ]]; then
    timestamp=--timestamp
fi
for component in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
    codesign --force --sign "$identity" --options runtime "$timestamp" \
        --preserve-metadata=entitlements "$sparkle_framework/Versions/B/$component"
done
codesign --force --sign "$identity" --options runtime "$timestamp" "$sparkle_framework"
codesign --verify --deep --strict "$sparkle_framework"
