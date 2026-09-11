#!/bin/bash
# Builds Anvil.app, code-signs it with a Developer ID Application
# certificate, packages it into a .dmg, and signs the .dmg too.
#
# Notarization is a separate, explicit step (notarize-dmg.sh) because it
# needs a one-time credential profile only the account holder can create
# (see that script's header) — this script never touches Apple ID
# credentials, API keys, or passwords.
#
# Usage: scripts/package-dmg.sh [version]
#   version defaults to the current git tag (or "0.0.0-dev" if untagged)

set -euo pipefail

SIGNING_IDENTITY="Developer ID Application: Vinicius Luciano Menezes Cotrim (U3H5DHZP65)"
BUNDLE_ID="com.viniciuscotrim.anvil"
APP_NAME="Anvil"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${1:-$(git describe --tags --always --dirty 2>/dev/null | sed 's/^v//' || echo "0.0.0-dev")}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$DIST_DIR/staging"
APP_BUNDLE="$STAGING_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"

echo "==> Building release binary ($VERSION, build $BUILD_NUMBER)"
swift build -c release

RELEASE_BIN="$ROOT_DIR/.build/out/Products/Release/$APP_NAME"
if [ ! -x "$RELEASE_BIN" ]; then
  # Fall back to whatever SwiftPM's active build system named it.
  RELEASE_BIN="$(find "$ROOT_DIR/.build" -path "*/Release/$APP_NAME" -type f -perm -u+x | head -1)"
fi
if [ -z "$RELEASE_BIN" ] || [ ! -x "$RELEASE_BIN" ]; then
  echo "error: could not find the built release binary" >&2
  exit 1
fi

echo "==> Assembling $APP_NAME.app"
rm -rf "$STAGING_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$RELEASE_BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

sed \
  -e "s/__VERSION__/$VERSION/" \
  -e "s/__BUILD__/$BUILD_NUMBER/" \
  "$ROOT_DIR/Resources/Info.plist" > "$APP_BUNDLE/Contents/Info.plist"

echo "==> Code-signing $APP_NAME.app (hardened runtime)"
codesign --force --deep --options runtime --timestamp \
  --sign "$SIGNING_IDENTITY" \
  "$APP_BUNDLE"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
spctl --assess --type execute --verbose "$APP_BUNDLE" || true # expected to fail until notarized

echo "==> Building $APP_NAME-$VERSION.dmg"
rm -f "$DMG_PATH"
ln -sf /Applications "$STAGING_DIR/Applications"
hdiutil create -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov -format UDZO \
  "$DMG_PATH"

echo "==> Code-signing $APP_NAME-$VERSION.dmg"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"

echo "==> Done: $DMG_PATH (signed, not yet notarized)"
echo "    Run scripts/notarize-dmg.sh \"$DMG_PATH\" next."
