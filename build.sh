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
codesign --force --deep --sign - "$APP"
echo "✅ Built $(pwd)/$APP"
