#!/bin/sh
set -e
export http_proxy=http://host.docker.internal:10808 https_proxy=http://host.docker.internal:10808
apt-get update -qq && apt-get install -y -qq mmdebstrap erofs-utils python3-minimal >/dev/null
export SOURCE_DATE_EPOCH=1761091200
mmdebstrap --variant=minbase --skip=essential/unlink \
  --setup-hook='mkdir -p "$1/var/cache/apt/archives"' --setup-hook='sync-in /work/out/debs /var/cache/apt/archives/' \
  --customize-hook='sync-out /var/cache/apt/archives /work/out/debs' --mode=root --aptopt="Acquire::Retries \"5\"" --aptopt='Acquire::http::Proxy "http://host.docker.internal:10808"' \
  --include=systemd,systemd-sysv,udev,podman,crun,nftables,uidmap,procps,iproute2,passt,bash,openssh-client,pipewire,pipewire-alsa,wireplumber,alsa-utils,cage,wayvnc,wlr-randr,firefox-esr,zenity,fonts-dejavu-core \
  --customize-hook='install -m755 /work/overlay-init "$1/sbin/overlay-init"' \
  --customize-hook='install -m644 /work/ready.service "$1/etc/systemd/system/ready.service"' \
  --customize-hook='chroot "$1" systemctl enable ready.service' \
  --customize-hook='chroot "$1" systemctl mask getty@tty1.service' \
  --customize-hook='chroot "$1" passwd -d root' \
  --customize-hook='rm -rf "$1/usr/share/doc" "$1/usr/share/man" "$1/var/cache/apt"/*' \
  --customize-hook='if [ -f /work/agent ]; then install -m755 /work/agent "$1/usr/local/bin/agent"; install -m644 /work/agent.service "$1/etc/systemd/system/"; install -m644 /work/agent-echo.service "$1/etc/systemd/system/"; install -m644 /work/agent@.service "$1/etc/systemd/system/"; chroot "$1" systemctl enable agent.service agent-echo.service agent@pty.service agent@sshfwd.service; fi' \
  --customize-hook='chroot "$1" useradd -m app; echo containers:300000:1000000 >> "$1/etc/subuid"; echo containers:300000:1000000 >> "$1/etc/subgid"' \
  --customize-hook='python3 /work/seccomp-vsock.py "$1/usr/share/containers/seccomp.json" "$1/etc/v2mac-seccomp.json"' \
  --customize-hook='install -m755 /work/spike05.sh "$1/usr/local/bin/"; install -m644 /work/spike05.service "$1/etc/systemd/system/"; true; install -m755 /work/spike09.sh "$1/usr/local/bin/"; install -m644 /work/spike09.service "$1/etc/systemd/system/"; true; install -m755 /work/spike07.sh "$1/usr/local/bin/"; install -m644 /work/heavy.html "$1/usr/local/share/"; install -m644 /work/spike07.service /work/agent-vnc.service "$1/etc/systemd/system/"; chroot "$1" systemctl enable spike07.service agent-vnc.service' \
  --customize-hook='install -m644 /work/containers.conf "$1/etc/containers/"' \
  trixie /tmp/root http://deb.debian.org/debian
mkfs.erofs -zlz4hc -T$SOURCE_DATE_EPOCH /work/out/rootfs.erofs /tmp/root >/dev/null
ls -la /work/out/rootfs.erofs
du -sh /tmp/root
