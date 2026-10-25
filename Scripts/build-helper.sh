#!/bin/sh
# Builds out/V2Mac Sandbox.app: the helper binary, out/Image and out/rootfs.erofs in Resources,
# ad-hoc signed with the virtualization entitlement (plan: "Packaging").
set -e
cd "$(dirname "$0")/.."
for f in out/Image out/rootfs.erofs; do [ -f "$f" ] || { echo "$f missing"; exit 1; }; done
for p in V2MacSandbox SandboxStub V2MacPty; do swift build -c release --product $p; done
APP="out/V2Mac Sandbox.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/"
[ -n "$VERSION" ] && plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
BIN=$(swift build -c release --show-bin-path)
cp "$BIN/V2MacSandbox" "$APP/Contents/MacOS/V2Mac Sandbox"
cp "$BIN/SandboxStub" "$APP/Contents/MacOS/v2mac-stub"
cp "$BIN/V2MacPty" "$APP/Contents/MacOS/v2mac-pty"
cp out/Image out/rootfs.erofs Resources/AppIcon.icns "$APP/Contents/Resources/"
# The helper's and generated apps' texts in fa/zh-Hans/ru (Apps.swift copies the .lproj folders).
xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$APP/Contents/Resources"
# Without an en.lproj, macOS picks the next language in the user's list (fa for en-US, fa) over English.
# An empty .strings keeps the folder a file the update manifest carries (package.sh).
mkdir -p "$APP/Contents/Resources/en.lproj" && : > "$APP/Contents/Resources/en.lproj/Localizable.strings"
# The base plugins may be built on (Scripts/build-base.sh); none means no store plugin installs.
[ -f out/images/bases.json ] && cp out/images/bases.json "$APP/Contents/Resources/"
codesign --force --sign - --entitlements Resources/V2MacSandbox.entitlements --options runtime "$APP"
codesign --verify --strict "$APP" && echo "built $APP"
