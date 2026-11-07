#!/usr/bin/env bash
# Builds build/FaceUnlock.app (release) and code-signs it.
# Usage: ./build.sh
#
# Signing identity: $FACEUNLOCK_SIGN_ID if set (SHA-1 hash or name, "-" for
# ad-hoc), otherwise the default Apple Development identity below if it is in
# the keychain, otherwise ad-hoc. A stable identity keeps the Keychain item,
# Camera and Accessibility grants valid across rebuilds; ad-hoc does not.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="FaceUnlock"
BUILD_DIR="${ROOT:?}/build"
APP="${BUILD_DIR:?}/${APP_NAME}.app"
MODEL="${ROOT}/Models/SFace.mlpackage"
DEFAULT_SIGN_ID="-"

# Only ever delete inside this project's build/ folder.
case "${APP}" in
  "${ROOT}/build/"*.app) ;;
  *) echo "refusing to touch unexpected path: ${APP}" >&2; exit 1 ;;
esac

[[ -d "${MODEL}" ]] || { echo "missing ${MODEL} (see tools/convert_sface.py)" >&2; exit 1; }

echo "==> swift build -c release"
swift build --package-path "${ROOT}" -c release
BIN_DIR="$(swift build --package-path "${ROOT}" -c release --show-bin-path)"

echo "==> assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_DIR}/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
cp "${ROOT}/Resources/Info.plist" "${APP}/Contents/Info.plist"
cp "${ROOT}/NOTICE" "${ROOT}/Models/LICENSE-SFace.txt" "${APP}/Contents/Resources/"

echo "==> compiling Core ML model"
xcrun coremlcompiler compile "${MODEL}" "${APP}/Contents/Resources/" >/dev/null
[[ -d "${APP}/Contents/Resources/SFace.mlmodelc" ]] || { echo "model compile failed" >&2; exit 1; }

SIGN_ID="${FACEUNLOCK_SIGN_ID:-}"
if [[ -z "${SIGN_ID}" ]]; then
  IDENTITIES="$(security find-identity -v -p codesigning)"
  if [[ "${IDENTITIES}" == *"${DEFAULT_SIGN_ID}"* ]]; then
    SIGN_ID="${DEFAULT_SIGN_ID}"
  else
    SIGN_ID="-"
    echo "warning: default signing identity not found; signing ad-hoc" >&2
  fi
fi

echo "==> signing with ${SIGN_ID}"
codesign --force --deep --options runtime --timestamp=none \
  --entitlements "${ROOT}/Resources/FaceUnlock.entitlements" \
  -s "${SIGN_ID}" "${APP}"
codesign --verify --deep --strict "${APP}"

echo "==> done: ${APP}"
