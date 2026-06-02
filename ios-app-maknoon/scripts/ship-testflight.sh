#!/usr/bin/env bash
#
# Ship Maknoon to TestFlight in one command.
#
# Pipeline:
#   1. Regenerate Maknoon.xcodeproj from project.yml so any compose /
#      Info.plist drift is healed.
#   2. Compute the build number from git rev-list count (monotonic,
#      deterministic, no manual bumps).
#   3. xcodebuild archive (Release, generic iOS device, automatic
#      signing). CURRENT_PROJECT_VERSION is overridden at the command
#      line so the .xcarchive bakes the right CFBundleVersion.
#   4. xcodebuild -exportArchive against ExportOptions.plist to
#      produce an upload-ready IPA at build/Maknoon-ipa/Maknoon.ipa.
#   5. xcrun altool --upload-app to push the IPA to App Store Connect
#      using an App Store Connect API key (issuer + key id + .p8 file
#      that altool finds at ~/.appstoreconnect/private_keys/AuthKey_<KeyID>.p8).
#
# After upload, App Store Connect spends ~5 to 15 minutes processing
# the build (extracting symbols, scanning for malware). Then it
# appears under TestFlight > iOS > Builds where it can be added to
# tester groups; the first build also needs Beta App Review for
# external testers (24 to 48 hr first time, faster on subsequent
# builds).
#
# Required environment variables:
#   ASC_API_ISSUER_ID         UUID of the App Store Connect API issuer
#   ASC_API_KEY_ID            10-character key id (eg ABCD123456)
#
# Optional environment variables:
#   ASC_API_KEY_PATH          Override location of the .p8 file. If
#                             unset, altool looks at
#                             ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
#                             and also ./private_keys/, ../private_keys/,
#                             and ~/.private_keys/ per Apple's docs.
#   SKIP_UPLOAD               Set to 1 to stop after the IPA is
#                             produced (useful when iterating locally).
#   ELABIFY_BUILD_COMMIT      Override commit hash baked into the
#                             build (default: short SHA from git).
#
# Usage:
#   export ASC_API_ISSUER_ID=12345678-1234-1234-1234-123456789012
#   export ASC_API_KEY_ID=ABCD123456
#   ./scripts/ship-testflight.sh

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT=Maknoon.xcodeproj
SCHEME=Maknoon
CONFIG=Release
ARCHIVE_PATH=build/Maknoon.xcarchive
IPA_DIR=build/Maknoon-ipa

# ─── Build identity ─────────────────────────────────────────────────────────

BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
BUILD_COMMIT="${ELABIFY_BUILD_COMMIT:-$(git rev-parse --short HEAD 2>/dev/null || echo dev)}"
BUILD_DATE_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
MARKETING_VERSION="$(grep -E '^\s+MARKETING_VERSION:' project.yml | head -1 | awk '{print $2}' | tr -d '"')"

echo "[ship] Marketing version : $MARKETING_VERSION"
echo "[ship] Build number      : $BUILD_NUMBER"
echo "[ship] Commit            : $BUILD_COMMIT"
echo "[ship] Build date        : $BUILD_DATE_UTC"

# ─── Pre-flight credentials ────────────────────────────────────────────────

if [ -z "${SKIP_UPLOAD:-}" ]; then
  : "${ASC_API_ISSUER_ID:?Set ASC_API_ISSUER_ID (App Store Connect API issuer UUID). Generate at appstoreconnect.apple.com > Users and Access > Integrations.}"
  : "${ASC_API_KEY_ID:?Set ASC_API_KEY_ID (10-character key id, eg ABCD123456).}"

  KEY_FILE="${ASC_API_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_API_KEY_ID}.p8}"
  if [ ! -f "$KEY_FILE" ]; then
    echo "[ship] FATAL: cannot find App Store Connect API key file at $KEY_FILE" >&2
    echo "             Download AuthKey_<KEY_ID>.p8 from App Store Connect and place it at:" >&2
    echo "               $HOME/.appstoreconnect/private_keys/AuthKey_${ASC_API_KEY_ID}.p8" >&2
    echo "             Or set ASC_API_KEY_PATH to its current location." >&2
    exit 1
  fi
fi

# ─── Regenerate xcodeproj ──────────────────────────────────────────────────

echo "[ship] Regenerating xcodeproj from project.yml..."
xcodegen generate >/dev/null

# ─── Clean previous artifacts ──────────────────────────────────────────────

rm -rf "$ARCHIVE_PATH" "$IPA_DIR"

# ─── Archive ───────────────────────────────────────────────────────────────

echo "[ship] Archiving (Release, generic iOS)..."
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    ELABIFY_BUILD_COMMIT="$BUILD_COMMIT" \
    ELABIFY_BUILD_DATE_UTC="$BUILD_DATE_UTC" \
    | { command -v xcbeautify >/dev/null && xcbeautify || cat; }

if [ ! -d "$ARCHIVE_PATH" ]; then
  echo "[ship] FATAL: archive failed; $ARCHIVE_PATH was not created." >&2
  echo "             Open Xcode and check signing identity / provisioning profile." >&2
  exit 1
fi

# ─── Export IPA ────────────────────────────────────────────────────────────

echo "[ship] Exporting IPA..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist ExportOptions.plist \
    -exportPath "$IPA_DIR" \
    -allowProvisioningUpdates \
    | { command -v xcbeautify >/dev/null && xcbeautify || cat; }

IPA_FILE="$IPA_DIR/Maknoon.ipa"
if [ ! -f "$IPA_FILE" ]; then
  echo "[ship] FATAL: IPA export failed; $IPA_FILE not found." >&2
  exit 1
fi
echo "[ship] IPA at $IPA_FILE ($(du -h "$IPA_FILE" | cut -f1))"

# ─── Upload ────────────────────────────────────────────────────────────────

if [ -n "${SKIP_UPLOAD:-}" ]; then
  echo "[ship] SKIP_UPLOAD set; stopping after IPA export."
  echo "[ship] To upload manually:"
  echo "         xcrun altool --upload-app -f $IPA_FILE -t ios \\"
  echo "                      --apiKey \$ASC_API_KEY_ID --apiIssuer \$ASC_API_ISSUER_ID"
  exit 0
fi

echo "[ship] Uploading to App Store Connect..."
xcrun altool --upload-app \
    -f "$IPA_FILE" \
    -t ios \
    --apiKey "$ASC_API_KEY_ID" \
    --apiIssuer "$ASC_API_ISSUER_ID"

echo "[ship] Done. Build #$BUILD_NUMBER uploaded."
echo "[ship] App Store Connect will spend ~5 to 15 min processing the build."
echo "[ship] Once it appears under TestFlight > iOS > Builds, add it to a tester group."
echo "[ship] For external testers, submit the build for Beta App Review the first time"
echo "       (24 to 48 hr); subsequent builds within the same major version skip review."
