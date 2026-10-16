#!/bin/zsh

set -euo pipefail
umask 077

SIGNING_DIR="${HOME}/Library/Application Support/Mac Explorer/Signing"
KEYCHAIN_PATH="${SIGNING_DIR}/MacExplorerSigning.keychain-db"
PASSWORD_FILE="${SIGNING_DIR}/keychain-password"
CERTIFICATE_FILE="${SIGNING_DIR}/MacExplorerSigning.cer.pem"
IDENTITY_NAME="Mac Explorer Local Distribution"

mkdir -p "${SIGNING_DIR}"

if [[ ! -s "${PASSWORD_FILE}" ]]; then
    openssl rand -hex 32 > "${PASSWORD_FILE}"
fi
KEYCHAIN_PASSWORD="$(<"${PASSWORD_FILE}")"

NEEDS_IDENTITY=1
if [[ -f "${KEYCHAIN_PATH}" ]]; then
    security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}" 2>/dev/null || true
    if security find-certificate -c "${IDENTITY_NAME}" "${KEYCHAIN_PATH}" >/dev/null 2>&1; then
        NEEDS_IDENTITY=0
    else
        security delete-keychain "${KEYCHAIN_PATH}" 2>/dev/null || rm -f "${KEYCHAIN_PATH}"
    fi
fi

if (( NEEDS_IDENTITY )); then
    PRIVATE_KEY_FILE="${SIGNING_DIR}/MacExplorerSigning.key.pem"
    PKCS12_FILE="${SIGNING_DIR}/MacExplorerSigning.p12"
    rm -f "${PRIVATE_KEY_FILE}" "${PKCS12_FILE}" "${CERTIFICATE_FILE}"

    openssl req -new -newkey rsa:3072 -x509 -sha256 -days 3650 -nodes \
        -subj "/CN=${IDENTITY_NAME}/O=Mac Explorer/OU=Local Distribution" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,digitalSignature,keyCertSign" \
        -addext "extendedKeyUsage=codeSigning" \
        -keyout "${PRIVATE_KEY_FILE}" \
        -out "${CERTIFICATE_FILE}" >/dev/null 2>&1

    openssl pkcs12 -export -legacy \
        -inkey "${PRIVATE_KEY_FILE}" \
        -in "${CERTIFICATE_FILE}" \
        -name "${IDENTITY_NAME}" \
        -passout "pass:${KEYCHAIN_PASSWORD}" \
        -out "${PKCS12_FILE}"

    security create-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"
    security set-keychain-settings -lut 21_600 "${KEYCHAIN_PATH}"
    security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"
    security import "${PKCS12_FILE}" \
        -k "${KEYCHAIN_PATH}" \
        -P "${KEYCHAIN_PASSWORD}" \
        -T /usr/bin/codesign >/dev/null
fi

security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"
security set-key-partition-list \
    -S apple-tool:,apple: \
    -s \
    -k "${KEYCHAIN_PASSWORD}" \
    "${KEYCHAIN_PATH}" >/dev/null
rm -f "${SIGNING_DIR}/MacExplorerSigning.key.pem" "${SIGNING_DIR}/MacExplorerSigning.p12"

KEYCHAIN_IS_SEARCHABLE=0
CURRENT_KEYCHAINS=()
while IFS= read -r line; do
    keychain="${line#*\"}"
    keychain="${keychain%\"*}"
    [[ -z "${keychain}" ]] && continue
    CURRENT_KEYCHAINS+=("${keychain}")
    [[ "${keychain}" == "${KEYCHAIN_PATH}" ]] && KEYCHAIN_IS_SEARCHABLE=1
done < <(security list-keychains -d user)
if (( ! KEYCHAIN_IS_SEARCHABLE )); then
    security list-keychains -d user -s "${CURRENT_KEYCHAINS[@]}" "${KEYCHAIN_PATH}"
fi

IDENTITY_HASH="$(security find-identity -v -p codesigning "${KEYCHAIN_PATH}" | awk -v name="${IDENTITY_NAME}" 'index($0, name) {print $2; exit}')"

if [[ -z "${IDENTITY_HASH}" ]]; then
    print -u2 "Unable to locate the Mac Explorer local signing identity."
    exit 1
fi

print -r -- "${IDENTITY_HASH}|${KEYCHAIN_PATH}"
