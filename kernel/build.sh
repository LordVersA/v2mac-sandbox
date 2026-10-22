#!/bin/sh
# Builds the guest kernel Image inside a Debian container: kernel.org LTS (kernel/VERSION) from
# allnoconfig plus config.fragment. Run through Scripts/build-kernel.sh. Output: /work/out/Image.
set -e
V=$(cat /work/kernel/VERSION)
command -v make >/dev/null || { apt-get update -qq && apt-get install -y -qq build-essential bc bison flex libssl-dev libelf-dev curl xz-utils >/dev/null; }
mkdir -p /work/out
[ -f /work/out/linux-$V.tar.xz ] || curl -sfL -o /work/out/linux-$V.tar.xz https://cdn.kernel.org/pub/linux/kernel/v${V%%.*}.x/linux-$V.tar.xz
cd /build && [ -d linux-$V ] || tar xJf /work/out/linux-$V.tar.xz
cd linux-$V
make allnoconfig >/dev/null
scripts/kconfig/merge_config.sh -m .config /work/kernel/config.fragment >/dev/null
make olddefconfig >/dev/null
fail=0
for o in $(grep '^CONFIG' /work/kernel/config.fragment | cut -d= -f1); do grep -q "^$o=y" .config || { echo "missing: $o"; fail=1; }; done
for o in $(sed -n 's/^# \(CONFIG_[A-Z0-9_]*\) is not set/\1/p' /work/kernel/config.fragment); do grep -q "^$o=y" .config && { echo "still on: $o"; fail=1; }; done
[ $fail = 0 ]
KBUILD_BUILD_TIMESTAMP="$(date -u -d @${SOURCE_DATE_EPOCH:-0})" KBUILD_BUILD_USER=v2mac KBUILD_BUILD_HOST=v2mac \
  make -j"$(nproc)" Image >/dev/null
cp arch/arm64/boot/Image /work/out/Image
echo "kernel $V built"
