#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"

BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
if [[ "$BUILD_DIR" != /* ]]; then BUILD_DIR="$ROOT/$BUILD_DIR"; fi
case "$BUILD_DIR" in
    /|"$ROOT") echo "unsafe BUILD_DIR: $BUILD_DIR" >&2; exit 1 ;;
esac

IDENTITY="${SIGNING_IDENTITY:--}"
APP_VERSION="${APP_VERSION:-3.1.19}"
APP_BUILD="${APP_BUILD:-3001019000001}"
FINAL_APP="$BUILD_DIR/SpaceNamer.app"

mkdir -p "$BUILD_DIR"
WORK_DIR=$(mktemp -d "$BUILD_DIR/.spacenamer-build.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT
APP="$WORK_DIR/SpaceNamer.app"
BIN="$APP/Contents/MacOS/SpaceNamer"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"

cp Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$APP_BUILD" "$APP/Contents/Info.plist"

echo "→ Compiling SpaceNamer $APP_VERSION ($APP_BUILD)…"
xcrun swiftc \
    -O \
    main.swift workspace.swift sparkle.swift panel.swift AppleScriptString.swift JSONStore.swift \
    -o "$BIN" \
    -F /System/Library/PrivateFrameworks \
    -F Vendor \
    -framework SkyLight \
    -framework Carbon \
    -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -target arm64-apple-macos14.0

echo "→ Copying resources…"
cp icon/AppIcon.icns "$APP/Contents/Resources/"
rsync -a --delete --exclude '_CodeSignature' Vendor/Sparkle.framework "$APP/Contents/Frameworks/"

if [ "$IDENTITY" = "-" ]; then
    echo "→ Ad-hoc signing development build…"
    codesign --force --deep --sign - "$APP"
else
    echo "→ Signing with Developer ID and hardened runtime…"
    codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
    codesign --force --options runtime --timestamp --entitlements SpaceNamer.entitlements --sign "$IDENTITY" "$APP"
fi

codesign --verify --deep --strict --verbose=2 "$APP"
rm -rf "$FINAL_APP"
mv "$APP" "$FINAL_APP"
echo "✓ Built $FINAL_APP"
