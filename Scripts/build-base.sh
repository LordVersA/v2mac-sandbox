#!/bin/sh
# Builds the base plugins are built on (plan §7 "Base"): the VM's own root, out/rootfs.erofs, as the
# Docker image v2mac/base, and out/images/bases.json, the `from` values plugins may use. The sandbox
# download already carries this root, so a plugin ships only its own layers on top of it. Locally the
# entry is `base@<image id>`; the release workflow pushes the image to GHCR and lists that digest.
set -e
cd "$(dirname "$0")/.."
[ -f out/rootfs.erofs ] || { echo "out/rootfs.erofs missing: run Scripts/build-rootfs.sh first"; exit 1; }
mkdir -p out/images
docker run --rm --platform linux/arm64 ${PROXY:+-e http_proxy=$PROXY -e https_proxy=$PROXY} -v "$PWD/out":/out debian:trixie sh -ec '
  apt-get update -qq && apt-get install -y -qq erofs-utils >/dev/null
  fsck.erofs --extract=/tmp/root --preserve /out/rootfs.erofs
  tar -C /tmp/root --numeric-owner --sort=name -cf /out/images/base-root.tar .'
docker import --platform linux/arm64 --change 'ENV LANG=C.UTF-8' --change 'ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
  out/images/base-root.tar v2mac/base >/dev/null
rm out/images/base-root.tar
printf '{"allowed": ["base@%s"]}\n' "$(docker image inspect --format '{{.Id}}' v2mac/base)" > out/images/bases.json
cat out/images/bases.json
