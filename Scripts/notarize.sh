#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 1 ]]; then
    echo 'Usage: bash Scripts/notarize.sh <notarytool-keychain-profile>' >&2
    exit 1
fi
PROFILE="$1"
bash Scripts/build.sh --install
APP="$PWD/Third Hand.app"
if ! codesign -dv --verbose=4 "$APP" 2>&1 | grep 'Authority=Developer ID Application:' >/dev/null; then
    echo 'Notarization requires a Developer ID Application certificate. Signing identity was not changed.' >&2
    exit 1
fi
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
ARCH=$(lipo -archs "$APP/Contents/MacOS/ThirdHand" | tr ' ' '-')
STAGE=$(mktemp -d "$PWD/.build/notarize.XXXXXX")
ditto "$APP" "$STAGE/Third Hand.app"
ditto -c -k --sequesterRsrc --keepParent "$STAGE/Third Hand.app" "$STAGE/submission.zip"
xcrun notarytool submit "$STAGE/submission.zip" --keychain-profile "$PROFILE" --wait --output-format json > "$STAGE/result.json"
STATUS=$(plutil -extract status raw -o - "$STAGE/result.json")
if [[ "$STATUS" != "Accepted" ]]; then
    echo "Notarization status: $STATUS. Details: $STAGE/result.json" >&2
    exit 1
fi
xcrun stapler staple "$STAGE/Third Hand.app"
xcrun stapler validate "$STAGE/Third Hand.app"
codesign --verify --strict "$STAGE/Third Hand.app"
spctl --assess --type execute --verbose "$STAGE/Third Hand.app"
mkdir -p dist
ARCHIVE="Third-Hand-$VERSION-$ARCH.zip"
ditto -c -k --sequesterRsrc --keepParent "$STAGE/Third Hand.app" "dist/$ARCHIVE"
(cd dist && shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256")
printf '\nNotarized release ready: dist/%s\n' "$ARCHIVE"
