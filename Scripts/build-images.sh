#!/bin/sh
# Builds the base images (plan §7) into out/images/<name>.tar and out/images/bases.json, the `from`
# values plugins may use. Locally each is `<name>@<image id>`; the release workflow pushes them to
# GHCR and lists `ghcr.io/lordversa/v2mac-<name>@<digest>` instead. PROXY= as for the other builds.
set -e
cd "$(dirname "$0")/.."
mkdir -p out/images
cp rootfs/sway.conf images/base-gui/
trap 'rm -f images/base-gui/sway.conf' EXIT
set -- --pull=false --platform linux/arm64 ${PROXY:+--build-arg http_proxy=$PROXY --build-arg https_proxy=$PROXY}
# BuildKit asks the registry about a digest FROM even with --pull=false, so the pinned Debian goes in
# under a local tag, checked to be exactly the pinned image (pulled once if missing).
pin=$(cat images/debian.lock)
docker image inspect "$pin" >/dev/null 2>&1 || docker pull --platform linux/arm64 "$pin"
image=$(docker image inspect --format '{{.Id}}' "$pin")
docker tag "$image" v2mac/debian-pinned
[ "$(docker image inspect --format '{{.Id}}' v2mac/debian-pinned)" = "$image" ] || { echo "pinned Debian mismatch"; exit 1; }
docker build "$@" --build-arg DEBIAN=v2mac/debian-pinned -f images/base/Containerfile -t v2mac/base images/base
docker build "$@" --build-arg BASE=v2mac/base -f images/base-cli/Containerfile -t v2mac/base-cli images/base-cli
docker build "$@" --build-arg BASE=v2mac/base -f images/base-gui/Containerfile -t v2mac/base-gui images/base-gui
list=""
for n in base base-cli base-gui; do
  docker save "v2mac/$n" -o "out/images/$n.tar"
  list="$list${list:+,}\"$n@$(docker image inspect --format '{{.Id}}' v2mac/$n)\""
done
printf '{"allowed": [%s]}\n' "$list" > out/images/bases.json
cat out/images/bases.json
