#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_DIR="${PROJECT_DIR}/dist/Mac Explorer.app"
CONTENTS_DIR="${APP_DIR}/Contents"

cd "${PROJECT_DIR}"
swift build -c release --product MacExplorer
SPARKLE_DIR="${PROJECT_DIR}/.build/artifacts/sparkle/Sparkle"
SPARKLE_FRAMEWORK="${SPARKLE_DIR}/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "${SPARKLE_FRAMEWORK}" ]] || { print -u2 "Sparkle framework is missing."; exit 1; }

if [[ -d "${APP_DIR}" ]]; then
    rm -rf "${APP_DIR}"
fi

mkdir -p "${CONTENTS_DIR}/MacOS" "${CONTENTS_DIR}/Resources" "${CONTENTS_DIR}/Frameworks"
cp "${PROJECT_DIR}/.build/release/MacExplorer" "${CONTENTS_DIR}/MacOS/Mac Explorer"
cp "${PROJECT_DIR}/Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"
cp "${PROJECT_DIR}/Resources/AppIcon.icns" "${CONTENTS_DIR}/Resources/AppIcon.icns"
cp "${PROJECT_DIR}/LICENSE" "${CONTENTS_DIR}/Resources/LICENSE"
cp "${SPARKLE_DIR}/LICENSE" "${CONTENTS_DIR}/Resources/Sparkle-LICENSE"
ditto "${SPARKLE_FRAMEWORK}" "${CONTENTS_DIR}/Frameworks/Sparkle.framework"
for LOCALIZATION_DIR in "${PROJECT_DIR}"/Resources/*.lproj; do
    if [[ -d "${LOCALIZATION_DIR}" ]]; then
        cp -R "${LOCALIZATION_DIR}" "${CONTENTS_DIR}/Resources/"
    fi
done

chmod 755 "${CONTENTS_DIR}/MacOS/Mac Explorer"
SIGNING_IDENTITY="${MAC_EXPLORER_SIGNING_IDENTITY:-}"
SIGNING_KEYCHAIN=""
if [[ -z "${SIGNING_IDENTITY}" ]]; then
    SIGNING_INFO="$("${SCRIPT_DIR}/ensure-local-signing-identity.sh")"
    SIGNING_IDENTITY="${SIGNING_INFO%%|*}"
    SIGNING_KEYCHAIN="${SIGNING_INFO#*|}"
fi

if [[ -n "${SIGNING_KEYCHAIN}" ]]; then
    codesign --force --deep --timestamp=none --sign "${SIGNING_IDENTITY}" "${APP_DIR}"
else
    codesign --force --deep --timestamp=none --sign "${SIGNING_IDENTITY}" "${APP_DIR}"
fi

codesign --verify --deep --strict "${APP_DIR}"
echo "Built ${APP_DIR}"
