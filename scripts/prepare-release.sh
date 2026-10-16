#!/bin/zsh
# Build and sign release assets locally. Does not publish or expose private keys.
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
cd "${PROJECT_DIR}"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)
[[ "${VERSION}" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' && "${BUILD}" =~ '^[1-9][0-9]*$' ]] || {
    print -u2 "Use a numeric major.minor or major.minor.patch version and positive build number in Info.plist."
    exit 1
}

swift package resolve
TOOLS="${PROJECT_DIR}/.build/artifacts/sparkle/Sparkle/bin"
PUBLIC_KEY=$("${TOOLS}/generate_keys" --account app.macexplorer.filemanager -p)
EXPECTED_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Resources/Info.plist)
[[ "${PUBLIC_KEY}" == "${EXPECTED_KEY}" ]] || {
    print -u2 "The signing key in this Mac's Keychain does not match this app. Restore the original key; do not generate a replacement."
    exit 1
}

RELEASE_DIR="${PROJECT_DIR}/dist/releases/v${VERSION}"
[[ ! -e "${RELEASE_DIR}" ]] || {
    print -u2 "Release assets already exist at ${RELEASE_DIR}. Use a new version or move the old directory aside."
    exit 1
}
"${SCRIPT_DIR}/build-app.sh"
mkdir -p "${RELEASE_DIR}"
ARCH=$(/usr/bin/uname -m)
ARCHIVE="Mac-Explorer-${VERSION}-${ARCH}.zip"
ditto -c -k --sequesterRsrc --keepParent "dist/Mac Explorer.app" "${RELEASE_DIR}/${ARCHIVE}"
"${TOOLS}/generate_appcast" --account app.macexplorer.filemanager \
    --download-url-prefix "https://github.com/RilakKuma2/Mac_file_explorer/releases/download/v${VERSION}/" \
    --link "https://github.com/RilakKuma2/Mac_file_explorer/releases/tag/v${VERSION}" \
    --maximum-deltas 0 "${RELEASE_DIR}"

STAGING_DIR=$(mktemp -d "${PROJECT_DIR}/dist/dmg-stage.XXXXXX")
ditto "dist/Mac Explorer.app" "${STAGING_DIR}/Mac Explorer.app"
ln -s /Applications "${STAGING_DIR}/Applications"
DMG="Mac-Explorer-${VERSION}-${ARCH}.dmg"
hdiutil create -volname "Mac Explorer" -srcfolder "${STAGING_DIR}" \
    -format UDZO "${RELEASE_DIR}/${DMG}"
hdiutil verify "${RELEASE_DIR}/${DMG}"
mkdir -p "${PROJECT_DIR}/old/dmg-staging"
mv "${STAGING_DIR}" "${PROJECT_DIR}/old/dmg-staging/"

print "Ready: ${RELEASE_DIR}"
print "Create a stable GitHub Release tagged v${VERSION} from the matching source commit."
print "Upload ${DMG}, ${ARCHIVE}, and appcast.xml, then mark it as the latest release."
