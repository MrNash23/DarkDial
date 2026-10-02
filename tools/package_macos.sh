#!/bin/sh
# Builds the signed (and optionally notarised) macOS release:
#
#     tools/package_macos.sh               build, sign, DMG
#     NOTARY_PROFILE=name tools/package_macos.sh    … and notarise + staple
#
# Result: dist/Darkdial-<version>.dmg
#
# Signing uses the "Developer ID Application" certificate in the keychain
# (override with SIGN_IDENTITY). The notary profile is created once with
#     xcrun notarytool store-credentials <name> --apple-id … --team-id … --password <app-specific password>
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/app"
VERSION="$(grep '^version:' "$APP_DIR/pubspec.yaml" | sed 's/version: *//; s/+.*//')"
BUILT="$APP_DIR/build/macos/Build/Products/Release/Darkdial.app"
DIST="$ROOT/dist"
APP="$DIST/Darkdial.app"
DMG="$DIST/Darkdial-$VERSION.dmg"
ENTITLEMENTS="$APP_DIR/macos/Runner/Release.entitlements"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
if [ -z "$IDENTITY" ]; then
  echo "No Developer ID Application certificate found." >&2
  exit 1
fi

echo "== build $VERSION"
(cd "$APP_DIR" && flutter build macos --release) | tail -1

rm -rf "$DIST"
mkdir -p "$DIST"
ditto "$BUILT" "$APP"

echo "== sign as $IDENTITY"
# Inside out: nested code first, the app last. Hardened runtime is required
# for notarisation.
find "$APP/Contents/Frameworks" \( -name '*.dylib' -o -name '*.framework' \) -depth | while read -r item; do
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$item"
done
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo "== disk image"
STAGE="$DIST/stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Darkdial.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Darkdial $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ -n "$NOTARY_PROFILE" ]; then
  echo "== notarise (takes a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$APP"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
else
  echo "== not notarised (set NOTARY_PROFILE); Gatekeeper will block this DMG on other Macs"
fi

echo "$DMG"
