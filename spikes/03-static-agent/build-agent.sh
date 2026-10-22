#!/bin/sh
# Builds the static agent in the swift:6.4.0 container (Xcode's compiler can't use the swift.org SDK).
# The SDK is kept in the v2mac-swiftpm volume; downloads go through the host's proxy on 10808.
set -e
cd "$(dirname "$0")"
P=http://host.docker.internal:10808
docker run --rm -e http_proxy=$P -e https_proxy=$P -v v2mac-swiftpm:/root/.swiftpm -v "$PWD":/w -w /w swift:6.4.0 sh -c '
  set -e
  swift sdk list | grep -q static || swift sdk install https://download.swift.org/swift-6.4.0-release/static-sdk/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz --checksum 47d2fd89eebfdf9eb4d536b6710414297f755c17926cdebc4742c08982b40a9e
  swift build -c release --swift-sdk aarch64-swift-linux-musl
  strip -o agent .build/out/Products/Release-staticlinux-aarch64/agent'
ls -la agent
