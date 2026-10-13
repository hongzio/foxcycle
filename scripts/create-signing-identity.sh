#!/bin/sh
# One-time setup: create a self-signed code-signing identity in a dedicated keychain.
#
# A stable signing identity keeps the app's designated requirement constant across rebuilds,
# so the Accessibility grant survives. The keychain is NOT added to the keychain search list.
#
# Remove completely with:
#   security delete-keychain ~/Library/Keychains/foxcycle-signing.keychain-db
#   rm -r ~/.config/foxcycle
set -eu

IDENTITY="FoxCycle Local Signing"
KEYCHAIN="$HOME/Library/Keychains/foxcycle-signing.keychain-db"
CONFIG_DIR="$HOME/.config/foxcycle"
PASSWORD_FILE="$CONFIG_DIR/signing-keychain-password"
# LibreSSL ships with macOS and emits PKCS#12 that `security import` accepts (OpenSSL 3+ defaults do not).
OPENSSL=/usr/bin/openssl

if [ -e "$KEYCHAIN" ]; then
    echo "Signing keychain already exists: $KEYCHAIN"
    security find-identity -p codesigning "$KEYCHAIN"
    exit 0
fi

umask 077
mkdir -p "$CONFIG_DIR"
WORK_DIR=$(mktemp -d)
cleanup() {
    status=$?
    rm -rf "$WORK_DIR"
    if [ "$status" -ne 0 ]; then
        security delete-keychain "$KEYCHAIN" 2>/dev/null || true
        rm -f "$PASSWORD_FILE"
        echo "Failed; partial state removed." >&2
    fi
}
trap cleanup EXIT

"$OPENSSL" rand -hex 24 > "$PASSWORD_FILE"
KEYCHAIN_PASSWORD=$(cat "$PASSWORD_FILE")
P12_PASSWORD=$("$OPENSSL" rand -hex 16)

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK_DIR/key.pem" -out "$WORK_DIR/cert.pem" \
    -subj "/CN=$IDENTITY" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" 2>/dev/null
"$OPENSSL" pkcs12 -export -name "$IDENTITY" \
    -inkey "$WORK_DIR/key.pem" -in "$WORK_DIR/cert.pem" \
    -out "$WORK_DIR/identity.p12" -passout "pass:$P12_PASSWORD"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"   # no auto-lock timeout
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$WORK_DIR/identity.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
# Let codesign use the key without an interactive "Always Allow" prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

echo "Created \"$IDENTITY\" in $KEYCHAIN"
security find-identity -p codesigning "$KEYCHAIN"
