#!/bin/bash
# Submits an already-signed .dmg (from package-dmg.sh) to Apple for
# notarization, waits for the result, and staples the ticket on success.
#
# ONE-TIME SETUP (you run this yourself — Claude never sees or handles
# your Apple credentials):
#
#   xcrun notarytool store-credentials "AnvilNotary" \
#     --apple-id <your-apple-id-email> \
#     --team-id U3H5DHZP65
#
# It'll prompt for an app-specific password (generate one at
# https://appleid.apple.com under Sign-In and Security > App-Specific
# Passwords — your regular Apple ID password won't work here). This
# stores the credential in your login keychain under the profile name
# "AnvilNotary"; every run of this script after that just references
# that name, never the password itself.
#
# Usage: scripts/notarize-dmg.sh <path-to-dmg> [keychain-profile]
#   keychain-profile defaults to "AnvilNotary"

set -euo pipefail

DMG_PATH="${1:?Usage: scripts/notarize-dmg.sh <path-to-dmg> [keychain-profile]}"
PROFILE="${2:-AnvilNotary}"

if [ ! -f "$DMG_PATH" ]; then
  echo "error: $DMG_PATH not found" >&2
  exit 1
fi

echo "==> Submitting $DMG_PATH for notarization (profile: $PROFILE)"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$PROFILE" --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$DMG_PATH"

echo "==> Verifying"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature -v "$DMG_PATH"

echo "==> Done: $DMG_PATH is signed, notarized, and stapled."
