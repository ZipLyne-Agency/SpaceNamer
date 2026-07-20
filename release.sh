#!/bin/bash
# Build, sign, notarize, publish, and feed a SpaceNamer release.
# Usage: ./release.sh <MAJOR.MINOR.PATCH> ["release notes"]
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"

VERSION="${1:?usage: ./release.sh <MAJOR.MINOR.PATCH> [notes]}"
NOTES="${2:-Bug fixes and improvements}"
REPO="${RELEASE_REPOSITORY:-ZipLyne-Agency/SpaceNamer}"
IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: ZipLyne LLC (DHGG5BA7J7)}"
KEY_ID="${NOTARY_KEY_ID:-UM7HDP6FK9}"
KEY="${NOTARY_KEY_FILE:-$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8}"
ISSUER="${NOTARY_ISSUER:?set NOTARY_ISSUER to the App Store Connect issuer UUID}"
BUILD_NUMBER="${BUILD_NUMBER:-$(scripts/build_number.py "$VERSION")}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
if [[ "$BUILD_DIR" != /* ]]; then BUILD_DIR="$ROOT/$BUILD_DIR"; fi
if [[ "$DIST_DIR" != /* ]]; then DIST_DIR="$ROOT/$DIST_DIR"; fi
case "$BUILD_DIR" in "$ROOT"/*) ;; *) echo "BUILD_DIR must be inside $ROOT" >&2; exit 1 ;; esac
case "$DIST_DIR" in "$ROOT"/*) ;; *) echo "DIST_DIR must be inside $ROOT" >&2; exit 1 ;; esac
APP="$BUILD_DIR/SpaceNamer.app"
DMG="$DIST_DIR/SpaceNamer-$VERSION.dmg"
BRIDGE_APPCAST="$DIST_DIR/spacenamer-releases-appcast.xml"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be numeric MAJOR.MINOR.PATCH" >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "BUILD_NUMBER must contain only digits" >&2; exit 1; }
[ "$IDENTITY" != "-" ] || { echo "release signing requires a Developer ID identity" >&2; exit 1; }
[ -f "$KEY" ] || { echo "missing notary key: $KEY" >&2; exit 1; }
if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1 ||
   gh api "repos/$REPO/git/ref/tags/v$VERSION" >/dev/null 2>&1; then
    echo "v$VERSION already exists; releases are immutable and will not be overwritten" >&2
    exit 1
fi

PYTHONPATH="$ROOT/scripts" python3 - "$VERSION" "$BUILD_NUMBER" "$ROOT/appcast.xml" <<'PYEOF'
import sys
from pathlib import Path
from update_appcast import _version_tuple, read_releases

version, build, path = sys.argv[1], int(sys.argv[2]), Path(sys.argv[3])
releases = read_releases(path)
if releases and _version_tuple(version) <= max(_version_tuple(item.version) for item in releases):
    raise SystemExit(f"version {version} is not newer than the current feed")
if releases and build <= max(item.build for item in releases):
    raise SystemExit(f"build {build} is not greater than the current feed")
PYEOF

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

ZIP=""
STAGE=""
APPCAST_UPDATED=0
OLD_APPCAST_SHA=$(gh api "repos/$REPO/contents/appcast.xml?ref=main" --jq .sha)
LOCAL_APPCAST_SHA=$(git hash-object appcast.xml)
[ "$OLD_APPCAST_SHA" = "$LOCAL_APPCAST_SHA" ] || {
    echo "local appcast.xml does not match canonical main; update the checkout before releasing" >&2
    exit 1
}
OLD_APPCAST_CONTENT=$(base64 < appcast.xml | tr -d '\n')
cleanup() {
    status=$?
    trap - EXIT
    if [ -n "$ZIP" ]; then rm -f "$ZIP"; fi
    if [ -n "$STAGE" ]; then rm -rf "$STAGE"; fi
    if [ "$status" -ne 0 ] && [ "$APPCAST_UPDATED" -eq 1 ]; then
        echo "→ Rolling back canonical appcast after release failure…" >&2
        current_sha=$(gh api "repos/$REPO/contents/appcast.xml?ref=main" --jq .sha 2>/dev/null || true)
        if [ -n "$current_sha" ]; then
            gh api --method PUT "repos/$REPO/contents/appcast.xml" \
                -f message="Roll back failed v$VERSION appcast" \
                -f content="$OLD_APPCAST_CONTENT" \
                -f sha="$current_sha" \
                -f branch=main >/dev/null || true
        fi
    fi
    exit "$status"
}
trap cleanup EXIT

echo "→ Building version $VERSION ($BUILD_NUMBER)"
SIGNING_IDENTITY="$IDENTITY" APP_VERSION="$VERSION" APP_BUILD="$BUILD_NUMBER" BUILD_DIR="$BUILD_DIR" ./build.sh

echo "→ Notarizing app…"
ZIP=$(mktemp /tmp/spacenamer-app.XXXXXX.zip)
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --key "$KEY" --key-id "$KEY_ID" --issuer "$ISSUER" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=4 "$APP"

echo "→ Packaging and Developer ID signing DMG…"
STAGE=$(mktemp -d /tmp/spacenamer-dmg.XXXXXX)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname SpaceNamer -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"

echo "→ Notarizing DMG…"
xcrun notarytool submit "$DMG" --key "$KEY" --key-id "$KEY_ID" --issuer "$ISSUER" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"

echo "→ Signing and verifying Sparkle update…"
SIGN_ARGS=()
if [ -n "${SPARKLE_KEY_FILE:-}" ]; then SIGN_ARGS+=(--ed-key-file "$SPARKLE_KEY_FILE"); fi
SIGINFO=$(./Vendor/bin/sign_update "${SIGN_ARGS[@]}" "$DMG")
EDSIG=$(printf '%s\n' "$SIGINFO" | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p')
[ -n "$EDSIG" ] || { echo "Sparkle signing did not return an EdDSA signature" >&2; exit 1; }
PUBLIC_KEY=$(plutil -extract SUPublicEDKey raw "$APP/Contents/Info.plist")
swift -e 'import Foundation; import CryptoKit
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: CommandLine.arguments[1])!)
let signature = Data(base64Encoded: CommandLine.arguments[2])!
let payload = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]), options: .mappedIfSafe)
guard key.isValidSignature(signature, for: payload) else { fatalError("invalid Sparkle EdDSA signature") }
print("Sparkle EdDSA signature verified")' "$PUBLIC_KEY" "$EDSIG" "$DMG"

LENGTH=$(stat -f%z "$DMG")
DATESTR=$(date -u '+%a, %d %b %Y %H:%M:%S %z')
DOWNLOAD_URL="https://github.com/$REPO/releases/download/v$VERSION/SpaceNamer-$VERSION.dmg"
python3 scripts/update_appcast.py \
    --appcast appcast.xml \
    --version "$VERSION" \
    --build "$BUILD_NUMBER" \
    --url "$DOWNLOAD_URL" \
    --signature "$EDSIG" \
    --length "$LENGTH" \
    --publication-date "$DATESTR" \
    --bridge-output "$BRIDGE_APPCAST"

echo "→ Staging draft GitHub release v$VERSION"
SOURCE_SHA=$(git rev-parse HEAD)
gh release create "v$VERSION" "$DMG" "$BRIDGE_APPCAST" \
    --repo "$REPO" --target "$SOURCE_SHA" --draft \
    --title "SpaceNamer v$VERSION" --notes "$NOTES"

APPCAST_CONTENT=$(base64 < appcast.xml | tr -d '\n')
gh api --method PUT "repos/$REPO/contents/appcast.xml" \
    -f message="Publish appcast for v$VERSION" \
    -f content="$APPCAST_CONTENT" \
    -f sha="$OLD_APPCAST_SHA" \
    -f branch=main >/dev/null
APPCAST_UPDATED=1

echo "→ Publishing verified release v$VERSION"
gh release edit "v$VERSION" --repo "$REPO" --draft=false --latest
APPCAST_UPDATED=0

echo "✓ Released SpaceNamer v$VERSION from $REPO"
echo "  Compatibility bridge: $BRIDGE_APPCAST"
