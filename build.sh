#!/bin/bash
# Builds NotchID.app into ./build without needing Xcode (Command Line Tools are enough).
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/NotchID.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/NotchID "$APP/Contents/MacOS/NotchID"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Sign with a stable local identity so Accessibility/Camera/Keychain permissions survive rebuilds.
KC="$HOME/Library/Keychains/notchid-signing.keychain-db"
if ./scripts/make-signing-identity.sh && security unlock-keychain -p notchid "$KC" 2>/dev/null; then
    codesign --force --deep --sign "NotchID Local Signing" --keychain "$KC" "$APP"
else
    echo "⚠️  Falling back to ad-hoc signing (permissions will need re-granting after each build)"
    codesign --force --deep --sign - "$APP"
fi
echo "✅ Built $(pwd)/$APP"
