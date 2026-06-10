#!/usr/bin/env bash
#
# Signs the built app, stages it with the LaunchAgent, builds a pkg with the
# postinstall script, signs the pkg, then notarizes and staples it.
#
# Prereqs:
#   - A Developer ID Application + Developer ID Installer certificate in your keychain.
#   - A stored notarytool credential profile, created once with:
#       xcrun notarytool store-credentials "netmonitor-notary" \
#         --apple-id "you@company.com" --team-id "TEAMID" --password "app-specific-pw"
#   - A built NetMonitor.app placed at ${APP_PATH} (build it in Xcode or via xcodebuild).
#
set -euo pipefail

# ---- EDIT THESE ----------------------------------------------------------
APP_NAME="NetMonitor"
BUNDLE_ID="com.mekari.netmonitor"
VERSION="1.0.0"
APP_SIGN_ID="Developer ID Application: Your Company (TEAMID)"
PKG_SIGN_ID="Developer ID Installer: Your Company (TEAMID)"
KEYCHAIN_PROFILE="netmonitor-notary"
# --------------------------------------------------------------------------

BUILD_DIR="./build"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"          # <-- your built .app goes here
STAGE="${BUILD_DIR}/stage"
SCRIPTS_DIR="./scripts"
LAUNCH_AGENT="./com.mekari.netmonitor.plist"

echo "==> 1/5 Signing app with hardened runtime"
codesign --force --options runtime --timestamp \
    --sign "${APP_SIGN_ID}" "${APP_PATH}"
codesign --verify --strict --verbose=2 "${APP_PATH}"

echo "==> 2/5 Staging payload (app + LaunchAgent)"
rm -rf "${STAGE}"
mkdir -p "${STAGE}/Applications"
mkdir -p "${STAGE}/Library/LaunchAgents"
cp -R "${APP_PATH}" "${STAGE}/Applications/"
cp "${LAUNCH_AGENT}" "${STAGE}/Library/LaunchAgents/"

echo "==> 3/5 Building component pkg"
COMPONENT_PKG="${BUILD_DIR}/${APP_NAME}-component.pkg"
pkgbuild --root "${STAGE}" \
    --scripts "${SCRIPTS_DIR}" \
    --identifier "${BUNDLE_ID}.pkg" \
    --version "${VERSION}" \
    --install-location "/" \
    "${COMPONENT_PKG}"

echo "==> 4/5 Signing pkg"
SIGNED_PKG="${BUILD_DIR}/${APP_NAME}-${VERSION}.pkg"
productsign --sign "${PKG_SIGN_ID}" "${COMPONENT_PKG}" "${SIGNED_PKG}"

echo "==> 5/5 Notarizing + stapling"
xcrun notarytool submit "${SIGNED_PKG}" --keychain-profile "${KEYCHAIN_PROFILE}" --wait
xcrun stapler staple "${SIGNED_PKG}"

echo ""
echo "Done: ${SIGNED_PKG}"
echo "Upload this pkg to Jamf Pro."
