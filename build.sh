#!/bin/bash
# Builds build/MailBar.app and signs it for this Mac.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/MailBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -parse-as-library \
    -target "$(uname -m)-apple-macos13.0" \
    -o "$APP/Contents/MacOS/MailBar" \
    Sources/MailBar/*.swift
cp Info.plist "$APP/Contents/Info.plist"

# Signing with the same certificate every time lets macOS keep MailBar's Keychain access
# across rebuilds. Run ./setup-signing.sh once to create it.
IDENTITY="MailBar Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "warning: \"$IDENTITY\" not found; signing ad hoc. Run ./setup-signing.sh to stop Keychain prompts after rebuilds." >&2
    codesign --force --sign - "$APP"
fi

echo "Built $APP"
