#!/bin/sh
# Builds out/rootfs.erofs in Docker (arm64, privileged for mmdebstrap's root mode). Needs out/agent.
set -e
cd "$(dirname "$0")/.."
[ -f out/agent ] || { echo "out/agent missing: run Scripts/build-agent.sh first"; exit 1; }
docker run --rm --privileged --platform linux/arm64 ${PROXY:+-e http_proxy=$PROXY -e https_proxy=$PROXY} \
  -e SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1761091200}" -v "$PWD":/work debian:trixie /work/rootfs/build.sh
