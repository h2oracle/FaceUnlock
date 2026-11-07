#!/usr/bin/env bash
# Builds FaceUnlock and packages it as dist/FaceUnlock-<version>.zip plus a
# .sha256 file. Notarisation and stapling happen only if you explicitly chose
# a signing identity (FACEUNLOCK_SIGN_ID, in the environment or
# signing.local.env) that is a "Developer ID Application" certificate AND
# $FACEUNLOCK_NOTARY_PROFILE names a notarytool keychain profile
# (xcrun notarytool store-credentials …). Otherwise it's skipped.
# Usage: ./release.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${ROOT:?}/build/FaceUnlock.app"
DIST="${ROOT:?}/dist"

case "${DIST}" in
  "${ROOT}/dist") ;;
  *) echo "refusing to touch unexpected path: ${DIST}" >&2; exit 1 ;;
esac

LOCAL_ENV="${ROOT}/signing.local.env"
if [[ -z "${FACEUNLOCK_SIGN_ID:-}" && -f "${LOCAL_ENV}" ]]; then
  # shellcheck source=/dev/null
  source "${LOCAL_ENV}"
fi
EXPLICIT_ID="${FACEUNLOCK_SIGN_ID:-}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${ROOT}/Resources/Info.plist")"
[[ -n "${VERSION}" ]] || { echo "could not read version from Info.plist" >&2; exit 1; }
ZIP="${DIST}/FaceUnlock-${VERSION}.zip"

# Notarisation needs a secure timestamp on the signature.
if [[ -n "${FACEUNLOCK_NOTARY_PROFILE:-}" && -n "${EXPLICIT_ID}" && "${EXPLICIT_ID}" != "-" ]]; then
  export FACEUNLOCK_TIMESTAMP=1
fi

echo "==> building ${VERSION}"
"${ROOT}/build.sh"

mkdir -p "${DIST}"
rm -f "${ZIP}" "${ZIP}.sha256"

package() {
  ditto -c -k --keepParent "${APP}" "${ZIP}"
}

package

AUTHORITY="$(codesign -dvv "${APP}" 2>&1 | grep -m1 '^Authority=' || true)"
if [[ -n "${EXPLICIT_ID}" && "${EXPLICIT_ID}" != "-" \
      && "${AUTHORITY}" == "Authority=Developer ID Application:"* \
      && -n "${FACEUNLOCK_NOTARY_PROFILE:-}" ]]; then
  echo "==> notarising (profile: ${FACEUNLOCK_NOTARY_PROFILE})"
  xcrun notarytool submit "${ZIP}" --keychain-profile "${FACEUNLOCK_NOTARY_PROFILE}" --wait
  echo "==> stapling"
  xcrun stapler staple "${APP}"
  rm -f "${ZIP}"
  package
else
  echo "==> skipping notarisation (needs an explicitly chosen Developer ID Application identity and FACEUNLOCK_NOTARY_PROFILE)"
fi

( cd "${DIST}" && shasum -a 256 "$(basename "${ZIP}")" > "$(basename "${ZIP}").sha256" )
echo "==> ${ZIP}"
cat "${ZIP}.sha256"
