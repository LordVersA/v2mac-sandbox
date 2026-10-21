#!/bin/sh
set -e
V=6.18.58
apt-get update -qq && apt-get install -y -qq build-essential bc bison flex libssl-dev libelf-dev curl xz-utils >/dev/null
cd /tmp && curl -sfL https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$V.tar.xz | tar xJ && cd linux-$V
make allnoconfig >/dev/null
scripts/kconfig/merge_config.sh -m .config /work/kernel.fragment >/dev/null
make olddefconfig >/dev/null
for o in $(grep -v '=n' /work/kernel.fragment | cut -d= -f1); do grep -q "^$o=y" .config || echo "missing: $o"; done
make -j12 Image >/dev/null
cp arch/arm64/boot/Image .config /work/out/
echo kernel done
