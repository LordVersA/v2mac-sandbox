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
cp out/Image out/rootfs.erofs "$APP/Contents/Resources/"
# The base images plugins may be built on (Scripts/build-images.sh); none means no store plugin installs.
[ -f out/images/bases.json ] && cp out/images/bases.json "$APP/Contents/Resources/"
codesign --force --sign - --entitlements Resources/V2MacSandbox.entitlements --options runtime "$APP"
codesign --verify --strict "$APP" && echo "built $APP"
