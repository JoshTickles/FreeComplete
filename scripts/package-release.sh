#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-local}"
case "$MODE" in local|notarize) ;; *) echo 'Usage: package-release.sh [local|notarize]' >&2; exit 1 ;; esac
APP="$ROOT/dist/FreeComplete.app"
[[ -d "$APP" ]] || { echo 'Build the app with scripts/build-app.sh first.' >&2; exit 1; }
codesign --verify --strict "$APP"
cmp -s "$ROOT/LICENSE" "$APP/Contents/Resources/Licenses/FreeComplete-Apache-2.0.txt" || {
    echo 'Bundled source license is missing or stale. Rebuild the app.' >&2; exit 1;
}
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD" =~ ^[1-9][0-9]*$ ]] || {
    echo 'Invalid app version/build metadata.' >&2; exit 1;
}
SUFFIX=local-pre-release
if [[ "$MODE" == notarize ]]; then SUFFIX=pre-release; fi
DEST="$ROOT/dist/FreeComplete-$VERSION-$BUILD-$SUFFIX.zip"
[[ ! -e "$DEST" ]] || { echo "Archive already exists: $DEST. Choose a new build number." >&2; exit 1; }
if [[ "$MODE" == notarize ]]; then
    : "${FREECOMPLETE_NOTARY_PROFILE:?Set an existing notarytool keychain profile. This command uploads the app to Apple.}"
    SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
    [[ "$SIGNATURE" == *'Authority=Developer ID Application:'* && "$SIGNATURE" == *'(runtime)'* ]] || {
        echo 'Notarization requires a Developer ID Application signature with hardened runtime.' >&2; exit 1;
    }
fi
STAGE="$(mktemp -d "$ROOT/dist/.release.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ARCHIVE="$STAGE/$(basename "$DEST")"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
if [[ "$MODE" == notarize ]]; then
    xcrun notarytool submit "$ARCHIVE" --keychain-profile "$FREECOMPLETE_NOTARY_PROFILE" --wait --output-format plist > "$STAGE/notary-result.plist"
    STATUS="$(/usr/libexec/PlistBuddy -c 'Print :status' "$STAGE/notary-result.plist")"
    [[ "$STATUS" == Accepted ]] || { echo "Apple notarization status: $STATUS. Release not produced." >&2; exit 1; }
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute "$APP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
fi
mv "$ARCHIVE" "$DEST"
shasum -a 256 "$DEST"
if [[ "$MODE" == local ]]; then
    echo 'Local pre-release archive only. Not notarized or verified for distribution to other Macs.'
else
    echo 'Notarized and stapled pre-release archive. Verify installation on a clean Mac before publishing.'
fi
