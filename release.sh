#!/bin/bash
set -e
cd "$(dirname "$0")"

APP_NAME="BO3 Launcher"
NOTARY_PROFILE="notarytool-profile"
DIST_ZIP="build/BO3-Launcher.zip"

command -v xcodegen >/dev/null 2>&1 || { echo "Install xcodegen: brew install xcodegen"; exit 1; }
[ -f Resources/BO3MacFix.tar.gz ] || { echo "Run ./scripts/build-macfix-payload.sh first"; exit 1; }

# Use a Developer ID from the keychain when there is one. Without it, sign
# ad-hoc: the app works, but it isn't notarized, so Gatekeeper makes players
# allow it once in System Settings (see the README's Install section).
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
if [ -n "$SIGN_ID" ]; then
  TEAM_ID=$(echo "$SIGN_ID" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')
  echo "==> Signing with $SIGN_ID"
else
  SIGN_ID="-"
  TEAM_ID=""
  echo "==> No Developer ID in the keychain: signing ad-hoc, no notarization"
fi

echo "==> Regenerating Xcode project..."
xcodegen generate --quiet

echo "==> Archiving Release..."
rm -rf build
xcodebuild archive \
  -project BO3Launcher.xcodeproj \
  -scheme BO3Launcher \
  -configuration Release \
  -archivePath build/BO3Launcher.xcarchive \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_ID" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  2>&1 | tail -10

ARCHIVE="build/BO3Launcher.xcarchive"
APP_PATH="$ARCHIVE/Products/Applications/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
  echo "❌ App not found in archive"
  ls -R "$ARCHIVE/Products/" 2>/dev/null
  exit 1
fi

echo "==> Re-signing..."
if [ "$SIGN_ID" = "-" ]; then
  codesign --force --deep --sign - --options runtime "$APP_PATH"
else
  codesign --force --deep --timestamp --sign "$SIGN_ID" --options runtime "$APP_PATH"
fi
codesign --verify --deep --strict "$APP_PATH"
codesign -dv --verbose=2 "$APP_PATH" 2>&1 | grep -E "Authority|TeamIdentifier|Signature|flags"

if [ "$SIGN_ID" != "-" ]; then
  echo "==> Submitting for notarization..."
  NOTARIZE_ZIP="build/$APP_NAME-notarize.zip"
  ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"
  xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_PATH"
  rm -f "$NOTARIZE_ZIP"
fi

echo "==> Creating distributable ZIP..."
rm -f "$DIST_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$DIST_ZIP"
shasum -a 256 "$DIST_ZIP"

VERSION=$(defaults read "$PWD/$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)
echo ""
echo "✅ Done! Distributable: $DIST_ZIP (version $VERSION)"
echo "   Publish it as a GitHub release tagged v$VERSION so Check for Updates offers it."
[ "$SIGN_ID" = "-" ] && echo "   It is signed ad-hoc, not notarized: players allow it once in System Settings."
exit 0
