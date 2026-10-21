#!/bin/sh
# Builds the guest kernel. The tarball is cached in out/ (download it on the host if Docker's network
# is slow); the tree lives in the /build volume so a config change only recompiles what changed.
set -e
V=6.18.58
command -v make >/dev/null || { apt-get update -qq && apt-get install -y -qq build-essential bc bison flex libssl-dev libelf-dev curl xz-utils >/dev/null; }
[ -f /work/out/linux-$V.tar.xz ] || curl -sfL -o /work/out/linux-$V.tar.xz https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$V.tar.xz
cd /build && [ -d linux-$V ] || tar xJf /work/out/linux-$V.tar.xz
cd linux-$V
make allnoconfig >/dev/null
scripts/kconfig/merge_config.sh -m .config /work/kernel.fragment >/dev/null
make olddefconfig >/dev/null
for o in $(grep '^CONFIG' /work/kernel.fragment | cut -d= -f1); do grep -q "^$o=y" .config || echo "missing: $o"; done
for o in $(sed -n 's/^# \(CONFIG_[A-Z0-9_]*\) is not set/\1/p' /work/kernel.fragment); do grep -q "^$o=y" .config && echo "still on: $o"; done
make -j12 Image 2>&1 | grep -E "^\s+(CC|AR|LD)" | awk "NR % 200 == 0 { print \"progress: \" NR \" files compiled\"; fflush() }"
cp arch/arm64/boot/Image .config /work/out/
echo kernel done
