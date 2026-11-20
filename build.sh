#!/bin/bash
# Builds NotchID.app into ./build without needing Xcode (Command Line Tools are enough).
#   ./build.sh            this Mac's architecture, signed with a stable local identity
#   ./build.sh --release  Apple Silicon + Intel, ad-hoc signed, packed as build/NotchID.zip
set -euo pipefail
cd "$(dirname "$0")"
APP=build/NotchID.app

assemble() {
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp "$1" "$APP/Contents/MacOS/NotchID"
    cp Resources/Info.plist "$APP/Contents/Info.plist"
}

if [[ "${1:-}" == "--release" ]]; then
    # One build per architecture, each in its own scratch folder, then one universal binary.
    # (`swift build --arch a --arch b` needs full Xcode.)
    binaries=()
    for triple in arm64-apple-macosx14.0 x86_64-apple-macosx14.0; do
        swift build -c release --triple "$triple" --scratch-path ".build/universal/$triple"
        binaries+=(".build/universal/$triple/release/NotchID")
    done
    mkdir -p build
    lipo -create "${binaries[@]}" -output build/NotchID-universal
    assemble build/NotchID-universal
    rm build/NotchID-universal
    # Plain ad-hoc: the designated requirement is this binary's hash, so no other program can pass
    # for NotchID and read the saved password. After an update macOS asks for the approvals again.
    codesign --force --sign - "$APP"
    rm -f build/NotchID.zip
    ditto -c -k --keepParent "$APP" build/NotchID.zip
    echo "✅ Built $(pwd)/build/NotchID.zip ($(lipo -archs "$APP/Contents/MacOS/NotchID"))"
    exit 0
fi

swift build -c release
assemble .build/release/NotchID

# Sign with a stable local identity so Accessibility/Camera/Keychain permissions survive rebuilds.
# macOS asks once per build to let `security` read the signing keychain's password (see scripts/sign.sh).
if ./scripts/sign.sh "$APP"; then :
elif [[ $? == 3 ]]; then
    exit 1 # denied: an ad-hoc build would lose NotchID's permissions, so stop instead
else
    echo "⚠️  Falling back to ad-hoc signing (permissions will need re-granting after each build)"
    codesign --force --deep --sign - "$APP"
fi
echo "✅ Built $(pwd)/$APP"
