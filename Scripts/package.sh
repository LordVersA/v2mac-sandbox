#!/bin/sh
# Zips out/V2Mac Sandbox.app into out/V2MacSandbox.zip and writes out/pin.json, the `SandboxPin` a
# V2Mac release (or a dev build's -debugSandboxPin) accepts. Usage: package.sh <download URL of the zip>
set -e
cd "$(dirname "$0")/.."
[ -n "$1" ] || { echo "usage: $0 <url>"; exit 2; }
rm -f out/V2MacSandbox.zip
ditto -c -k --keepParent "out/V2Mac Sandbox.app" out/V2MacSandbox.zip
sum() { shasum -a 256 "$1" | cut -d' ' -f1; }
cat > out/pin.json <<JSON
{"url": "$1", "sha256": "$(sum out/V2MacSandbox.zip)", "executableSHA256": "$(sum "out/V2Mac Sandbox.app/Contents/MacOS/V2Mac Sandbox")", "size": $(stat -f%z out/V2MacSandbox.zip)}
JSON
cat out/pin.json
