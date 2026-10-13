#!/bin/sh
# Run the unit tests (Swift Testing).
#
# Command Line Tools (no Xcode) ship Swift Testing's macro plugin in a directory SwiftPM does not
# pass to the compiler, so point at it explicitly there. With Xcode this is a plain `swift test`.
set -eu
cd "$(dirname "$0")/.."

DEVELOPER_DIR=$(xcode-select -p)
PLUGIN_DIR="$DEVELOPER_DIR/usr/lib/swift/host/plugins/testing"
case "$DEVELOPER_DIR" in
    *CommandLineTools*)
        if [ -d "$PLUGIN_DIR" ]; then
            exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGIN_DIR" "$@"
        fi
        ;;
esac
exec swift test "$@"
