#!/bin/sh
# Builds the VM's read-only root: Debian 13 arm64 via mmdebstrap, only Debian's signed archive,
# reproducible with SOURCE_DATE_EPOCH, packed as lz4hc erofs. Run through Scripts/build-rootfs.sh.
# Needs /work/out/agent (Scripts/build-agent.sh). Output: /work/out/rootfs.erofs.
set -e
apt-get update -qq && apt-get install -y -qq mmdebstrap erofs-utils python3-minimal curl unzip >/dev/null
: "${SOURCE_DATE_EPOCH:=1761091200}"
export SOURCE_DATE_EPOCH
R=/work/rootfs
. $R/xray.lock
[ -f /work/out/$ASSET ] || curl -fsSL -o /work/out/$ASSET https://github.com/XTLS/Xray-core/releases/download/$VERSION/$ASSET
echo "$SHA256  /work/out/$ASSET" | sha256sum -c -
rm -rf /tmp/xray && unzip -q /work/out/$ASSET xray -d /tmp/xray
set --
[ -n "$http_proxy" ] && set -- "--aptopt=Acquire::http::Proxy \"$http_proxy\""
mkdir -p /work/out/debs
mmdebstrap --variant=minbase --mode=root --aptopt='Acquire::Retries "5"' "$@" \
  --setup-hook='mkdir -p "$1/var/cache/apt/archives"' --setup-hook='sync-in /work/out/debs /var/cache/apt/archives/' \
  --customize-hook='sync-out /var/cache/apt/archives /work/out/debs' \
  --include=systemd,systemd-sysv,udev,podman,crun,nftables,uidmap,procps,iproute2,passt,e2fsprogs,socat,iputils-ping,openssh-client,sway,wayvnc,wlr-randr,wtype,zenity,fonts-dejavu-core,fonts-vazirmatn,pipewire,pipewire-alsa,pipewire-pulse,wireplumber,alsa-utils \
  --customize-hook="install -m755 $R/overlay-init \"\$1/sbin/overlay-init\"" \
  --customize-hook="install -m755 /work/out/agent \"\$1/usr/local/bin/v2mac-agent\"" \
  --customize-hook="install -m755 /tmp/xray/xray \"\$1/usr/local/bin/xray\"" \
  --customize-hook="install -D -m755 $R/sandbox.sh \"\$1/usr/local/lib/v2mac/sandbox.sh\"" \
  --customize-hook="install -m755 $R/probe.sh \"\$1/usr/local/lib/v2mac/probe.sh\"" \
  --customize-hook="install -m644 $R/v2mac-agent.service $R/v2mac-data.service \"\$1/etc/systemd/system/\"" \
  --customize-hook='chroot "$1" systemctl enable v2mac-agent.service v2mac-data.service' \
  --customize-hook='chroot "$1" systemctl mask getty@tty1.service serial-getty@hvc0.service' \
  --customize-hook='mkdir -p "$1/data"; chroot "$1" useradd -m app; echo containers:300000:1000000 >> "$1/etc/subuid"; echo containers:300000:1000000 >> "$1/etc/subgid"' \
  --customize-hook="python3 $R/seccomp-vsock.py \"\$1/usr/share/containers/seccomp.json\" \"\$1/etc/v2mac-seccomp.json\"" \
  --customize-hook='echo "SUBSYSTEM==\"sound\", MODE=\"0666\"" > "$1/etc/udev/rules.d/60-v2mac-sound.rules"' \
  --customize-hook="install -D -m644 $R/sway.conf \"\$1/etc/v2mac/sway.conf\"" \
  --customize-hook="install -D -m644 $R/pipewire-alsa.conf \"\$1/etc/pipewire/pipewire.conf.d/v2mac-alsa.conf\"" \
  --customize-hook="install -m644 $R/containers.conf \"\$1/etc/containers/\"" \
  `# mmdebstrap keeps --aptopt here: a build proxy would be every app's apt proxy in the VM.` \
  --customize-hook='rm -f "$1/etc/apt/apt.conf.d/99mmdebstrap"' \
  --customize-hook='rm -rf "$1/usr/share/doc" "$1/usr/share/man" "$1/var/cache/apt"/* "$1/var/lib/apt/lists"/*' \
  trixie /tmp/root http://deb.debian.org/debian
mkfs.erofs -zlz4hc -T"$SOURCE_DATE_EPOCH" /work/out/rootfs.erofs /tmp/root >/dev/null
ls -la /work/out/rootfs.erofs
