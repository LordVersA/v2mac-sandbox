#!/bin/sh
# Release CI (docs/delta-updates.md D2): one bsdiff patch from the rootfs of each of the last 3 releases
# to out/rootfs.erofs, into out/patches/ with the old file's SHA-256 beside it; package.sh adds them to
# the manifest. Usage: make-patches.sh <new tag>. Needs gh, unzip and bsdiff.
set -e
cd "$(dirname "$0")/.."
mkdir -p out/patches
old=$(mktemp -d)
for tag in $(gh release list --limit 100 --json tagName --jq '.[].tagName' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | grep -vx "$1" | sort -V | tail -3); do
  rm -rf "$old"/*
  # Releases from before the manifest only have the whole bundle zipped.
  if gh release download "$tag" -p Resources_rootfs.erofs.zip -D "$old" 2>/dev/null; then
    unzip -q "$old/Resources_rootfs.erofs.zip" -d "$old"
  else
    gh release download "$tag" -p V2MacSandbox.zip -D "$old"
    unzip -q -j "$old/V2MacSandbox.zip" "V2Mac Sandbox.app/Contents/Resources/rootfs.erofs" -d "$old"
  fi
  patch="out/patches/Resources_rootfs.erofs.from-${tag#v}.bsdiff"
  bsdiff "$old/rootfs.erofs" out/rootfs.erofs "$patch"
  sha256sum "$old/rootfs.erofs" | cut -d' ' -f1 > "$patch.from"
  ls -l "$patch"
done
rm -rf "$old"
