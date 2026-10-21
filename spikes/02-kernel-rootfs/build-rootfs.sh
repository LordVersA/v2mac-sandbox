#!/bin/sh
set -e
apt-get update -qq && apt-get install -y -qq mmdebstrap erofs-utils >/dev/null
export SOURCE_DATE_EPOCH=1761091200
mmdebstrap --variant=minbase --mode=root --aptopt="Acquire::Retries \"5\"" \
  --include=systemd,systemd-sysv,udev,podman,crun,nftables,uidmap,procps \
  --customize-hook='install -m755 /work/overlay-init "$1/sbin/overlay-init"' \
  --customize-hook='install -m644 /work/ready.service "$1/etc/systemd/system/ready.service"' \
  --customize-hook='chroot "$1" systemctl enable ready.service' \
  --customize-hook='chroot "$1" systemctl mask getty@tty1.service' \
  --customize-hook='chroot "$1" passwd -d root' \
  --customize-hook='rm -rf "$1/usr/share/doc" "$1/usr/share/man" "$1/var/cache/apt"/*' \
  --customize-hook='if [ -f /work/agent ]; then install -m755 /work/agent "$1/usr/local/bin/agent"; install -m644 /work/agent.service "$1/etc/systemd/system/"; install -m644 /work/agent-echo.service "$1/etc/systemd/system/"; chroot "$1" systemctl enable agent.service agent-echo.service; fi' \
  trixie /tmp/root http://deb.debian.org/debian
mkfs.erofs -zlz4hc --all-root -T$SOURCE_DATE_EPOCH /work/out/rootfs.erofs /tmp/root >/dev/null
ls -la /work/out/rootfs.erofs
du -sh /tmp/root
