#!/usr/bin/env bash
set -euo pipefail

# Simple DMG builder for claude-pet.
# Usage:
#   ./scripts/make-dmg.sh
#   APP_VERSION=1.0.1 ./scripts/make-dmg.sh
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)" ./scripts/make-dmg.sh   # release build for notarization

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${ROOT_DIR}/claude-pet.xcodeproj"
SCHEME_NAME="claude-pet"
CONFIGURATION="Release"
APP_NAME="claude-pet"
APP_VERSION="${APP_VERSION:-1.0.0}"
DIST_DIR="${ROOT_DIR}/dist"
DERIVED_DIR="${DIST_DIR}/DerivedData"
STAGING_DIR="${DIST_DIR}/dmg-staging"
VOLUME_NAME="${APP_NAME} ${APP_VERSION}"
DMG_PATH="${DIST_DIR}/${APP_NAME}-${APP_VERSION}.dmg"
BUILD_LOG="/tmp/${APP_NAME}-build.log"
DMG_LOG="/tmp/${APP_NAME}-dmg.log"

# Hardened runtime (required for notarization) only works with a real Developer ID:
# an ad-hoc signed app can't load the embedded Sparkle.framework under library validation.
SIGN_ARGS=()
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  SIGN_ARGS=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=${DEVELOPER_ID}" ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp)
  echo "Signing with ${DEVELOPER_ID} (hardened runtime on)"
else
  echo "No DEVELOPER_ID set: local ad-hoc build, not notarizable"
fi

echo "Building ${APP_NAME}.app..."
xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME_NAME}" \
  -configuration "${CONFIGURATION}" \
  -derivedDataPath "${DERIVED_DIR}" \
  ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} \
  clean build \
  >"${BUILD_LOG}"

APP_PATH="${DERIVED_DIR}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
if [[ ! -d "${APP_PATH}" ]]; then
  echo "Build failed - app not found at ${APP_PATH}"
  echo "See ${BUILD_LOG}"
  exit 1
fi

echo "Preparing DMG staging..."
rm -rf "${STAGING_DIR}" "${DMG_PATH}"
mkdir -p "${STAGING_DIR}" "${DIST_DIR}"
cp -R "${APP_PATH}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

echo "Creating DMG..."
hdiutil create \
  -volname "${VOLUME_NAME}" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}" \
  >"${DMG_LOG}"

echo "Done: ${DMG_PATH}"
echo "Next step for public release: sign + notarize this DMG."
