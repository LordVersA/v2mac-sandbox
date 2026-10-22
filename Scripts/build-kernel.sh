#!/bin/sh
# Builds out/Image in Docker (arm64). The kernel tree is kept in the v2mac-kbuild-src volume, so a config
# change only recompiles what changed. Set PROXY=http://host.docker.internal:<port> to download through one.
set -e
cd "$(dirname "$0")/.."
docker run --rm --platform linux/arm64 ${PROXY:+-e http_proxy=$PROXY -e https_proxy=$PROXY} \
  -e SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1761091200}" \
  -v v2mac-kbuild-src:/build -v "$PWD":/work debian:trixie /work/kernel/build.sh
