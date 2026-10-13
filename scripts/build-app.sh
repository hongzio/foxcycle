#!/bin/sh
# Build a SwiftPM executable product and wrap it in a signed, Dock-less (LSUIElement) .app.
#
#   scripts/build-app.sh                         # FoxCycle.app from the FoxCycle product
#   BENCH=1 scripts/build-app.sh                 # FoxCycleBench.app: same app + synthesized-input bench
#   PRODUCT=foxcycle-poc scripts/build-app.sh    # wrap the PoC instead (same bundle identity)
#   ARCHS="arm64 x86_64" scripts/build-app.sh    # universal binary (default: this Mac's architecture)
#
# Signs with the identity from scripts/create-signing-identity.sh so TCC grants persist.
set -eu

PRODUCT="${PRODUCT:-FoxCycle}"
CONFIGURATION="${CONFIGURATION:-release}"
BENCH="${BENCH:-0}"
if [ "$BENCH" = 1 ]; then
    APP_NAME="${APP_NAME:-FoxCycleBench}"
else
    APP_NAME="${APP_NAME:-FoxCycle}"
fi
BUNDLE_ID="${BUNDLE_ID:-com.hongzio.foxcycle}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
ARCHS="${ARCHS:-}"
MIN_SYSTEM_VERSION="14.0"

IDENTITY="FoxCycle Local Signing"
KEYCHAIN="$HOME/Library/Keychains/foxcycle-signing.keychain-db"
PASSWORD_FILE="$HOME/.config/foxcycle/signing-keychain-password"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT_DIR="$ROOT/build"
APP="$OUT_DIR/$APP_NAME.app"

if [ ! -e "$KEYCHAIN" ] || [ ! -e "$PASSWORD_FILE" ]; then
    echo "Signing identity missing. Run scripts/create-signing-identity.sh first." >&2
    exit 1
fi

cd "$ROOT"
# Bench builds compile the bench driver in and use their own build directory, so switching between
# the two never leaves a bench binary behind in the regular one.
SCRATCH="$ROOT/.build"
set -- -c "$CONFIGURATION"
if [ "$BENCH" = 1 ]; then
    SCRATCH="$ROOT/.build/bench"
    set -- "$@" -Xswiftc -DFOXCYCLE_BENCH
fi
BINARIES=""
if [ -z "$ARCHS" ]; then
    swift build "$@" --scratch-path "$SCRATCH" --product "$PRODUCT"
    BINARIES="$(swift build "$@" --scratch-path "$SCRATCH" --show-bin-path)/$PRODUCT"
else
    for ARCH in $ARCHS; do
        # A scratch path per architecture keeps the native build's cache intact.
        TARGET="--scratch-path $SCRATCH/$ARCH --triple $ARCH-apple-macosx$MIN_SYSTEM_VERSION"
        # shellcheck disable=SC2086 # option words
        swift build "$@" $TARGET --product "$PRODUCT"
        # shellcheck disable=SC2086
        BINARIES="$BINARIES $(swift build "$@" $TARGET --show-bin-path)/$PRODUCT"
    done
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
# shellcheck disable=SC2086 # one path per architecture
lipo -create -output "$APP/Contents/MacOS/$PRODUCT" $BINARIES
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$PRODUCT</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_SYSTEM_VERSION</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

security unlock-keychain -p "$(cat "$PASSWORD_FILE")" "$KEYCHAIN"
codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"

echo "Built $APP"
codesign -d -r- "$APP" 2>&1 | grep designated
