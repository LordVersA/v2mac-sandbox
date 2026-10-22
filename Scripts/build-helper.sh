#!/bin/sh
# Builds out/V2Mac Sandbox.app: the helper binary, out/Image and out/rootfs.erofs in Resources,
# ad-hoc signed with the virtualization entitlement (plan: "Packaging").
set -e
cd "$(dirname "$0")/.."
for f in out/Image out/rootfs.erofs; do [ -f "$f" ] || { echo "$f missing"; exit 1; }; done
swift build -c release --product V2MacSandbox
APP="out/V2Mac Sandbox.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/"
[ -n "$VERSION" ] && plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
cp "$(swift build -c release --show-bin-path)/V2MacSandbox" "$APP/Contents/MacOS/V2Mac Sandbox"
cp out/Image out/rootfs.erofs "$APP/Contents/Resources/"
codesign --force --sign - --entitlements Resources/V2MacSandbox.entitlements --options runtime "$APP"
codesign --verify --strict "$APP" && echo "built $APP"
