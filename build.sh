#!/usr/bin/env bash
# Builds build/FaceUnlock.app (release) and code-signs it.
# Usage: ./build.sh
#
# Signing identity, in order:
#   1. $FACEUNLOCK_SIGN_ID if set (SHA-1 hash or certificate name; "-" = ad-hoc)
#   2. the first valid "Developer ID Application" identity in your keychain
#   3. the first valid "Apple Development" identity
#   4. ad-hoc
# A stable identity keeps the Keychain item and the Camera/Accessibility
# grants valid across rebuilds; ad-hoc signing does not.
# Set FACEUNLOCK_TIMESTAMP=1 to request a secure timestamp (needed for
# notarisation; contacts Apple's timestamp server).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="FaceUnlock"
BUILD_DIR="${ROOT:?}/build"
APP="${BUILD_DIR:?}/${APP_NAME}.app"
MODEL="${ROOT}/Models/SFace.mlpackage"

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
SIGN_NAME=""
if [[ -z "${SIGN_ID}" ]]; then
  IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  for KIND in "Developer ID Application" "Apple Development"; do
    LINE="$(printf '%s\n' "${IDENTITIES}" | grep -m1 "\"${KIND}: " || true)"
    if [[ -n "${LINE}" ]]; then
      SIGN_ID="$(printf '%s\n' "${LINE}" | awk '{print $2}')"
      SIGN_NAME="$(printf '%s\n' "${LINE}" | sed -E 's/^[^"]*"(.*)"$/\1/')"
      break
    fi
  done
fi
if [[ -z "${SIGN_ID}" || "${SIGN_ID}" == "-" ]]; then
  SIGN_ID="-"
  SIGN_NAME="ad-hoc"
fi

TIMESTAMP_FLAG="--timestamp=none"
if [[ "${FACEUNLOCK_TIMESTAMP:-0}" == "1" && "${SIGN_ID}" != "-" ]]; then
  TIMESTAMP_FLAG="--timestamp"
fi

echo "==> signing with: ${SIGN_NAME:-${SIGN_ID}}"
codesign --force --deep --options runtime "${TIMESTAMP_FLAG}" \
  --entitlements "${ROOT}/Resources/FaceUnlock.entitlements" \
  -s "${SIGN_ID}" "${APP}"
codesign --verify --deep --strict "${APP}"

echo "==> done: ${APP}"
