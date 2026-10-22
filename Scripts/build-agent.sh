#!/bin/sh
# Builds out/agent with the Swift Static Linux SDK in the swift:6.4.0 container (Xcode's compiler
# rejects the swift.org SDK, M0 0.3). The workspace is mounted so ../app resolves. The SDK is cached in the v2mac-swiftpm volume.
set -e
cd "$(dirname "$0")/.."
mkdir -p out
docker run --rm --platform linux/arm64 ${PROXY:+-e http_proxy=$PROXY -e https_proxy=$PROXY} \
  -v v2mac-swiftpm:/root/.swiftpm -v "$PWD/..":/w -w /w/sandbox swift:6.4.0 sh -c '
  set -e
  swift sdk list | grep -q static || swift sdk install https://download.swift.org/swift-6.4.0-release/static-sdk/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz --checksum 47d2fd89eebfdf9eb4d536b6710414297f755c17926cdebc4742c08982b40a9e
  set -- -c release --product Agent --swift-sdk aarch64-swift-linux-musl --scratch-path .build-linux
  swift build "$@"
  strip -o out/agent "$(swift build "$@" --show-bin-path)/Agent"'
ls -la out/agent
