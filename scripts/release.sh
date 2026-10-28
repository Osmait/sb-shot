#!/bin/bash
# Builds sb-shot for distribution and packages it as a DMG in dist/.
#
#   scripts/release.sh 0.2.0
#
# Without signing settings the app is signed ad hoc, which is fine for testing
# but macOS will refuse to open it on other Macs. To produce a release that
# opens anywhere, set:
#
#   SIGN_IDENTITY   "Developer ID Application: Your Name (TEAMID)"
#   TEAM_ID         Your Apple Developer team ID
#
# and, to notarize, either a notarytool keychain profile:
#
#   NOTARY_PROFILE  Name given to `xcrun notarytool store-credentials`
#
# or an App Store Connect API key:
#
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID
#
# Optional: BUILD_NUMBER (defaults to 1).
set -euo pipefail

VERSION="${1:?Usage: scripts/release.sh <version>}"
VERSION="${VERSION#v}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/release"
DIST="$ROOT/dist"
APP="$BUILD/Build/Products/Release/SbShot.app"
DMG="$DIST/SbShot-$VERSION.dmg"

cd "$ROOT"
rm -rf "$BUILD" "$DMG"
mkdir -p "$DIST"

signing=(CODE_SIGN_STYLE=Manual)
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    echo "==> Signing with $SIGN_IDENTITY"
    # Notarization requires the hardened runtime and a secure timestamp.
    signing+=(CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="${TEAM_ID:?TEAM_ID is required with SIGN_IDENTITY}"
              ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp)
else
    echo "==> No SIGN_IDENTITY: signing ad hoc (the app won't open on other Macs without a warning)"
    signing+=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
fi

echo "==> Building sb-shot $VERSION ($BUILD_NUMBER)"
xcodebuild -project sb-shot.xcodeproj -scheme SbShot -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath "$BUILD" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    "${signing[@]}" \
    -quiet build
codesign --verify --deep --strict "$APP"

echo "==> Creating $(basename "$DMG")"
staging="$BUILD/dmg"
mkdir -p "$staging"
cp -R "$APP" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "SbShot" -srcfolder "$staging" -fs HFS+ -format UDZO -ov -quiet "$DMG"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"

    notary=()
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        notary=(--keychain-profile "$NOTARY_PROFILE")
    elif [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
        notary=(--key "$NOTARY_KEY_PATH" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER_ID:?}")
    fi

    if (( ${#notary[@]} )); then
        echo "==> Notarizing (this usually takes a few minutes)"
        xcrun notarytool submit "$DMG" "${notary[@]}" --wait
        xcrun stapler staple "$DMG"
        spctl --assess --type open --context context:primary-signature --verbose "$DMG"
    else
        echo "==> No notarization credentials: skipping notarization"
    fi
fi

echo "==> Done: $DMG"
shasum -a 256 "$DMG"
