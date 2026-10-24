#!/bin/sh
# The gateway and mini VMs (plan §3–4), run by the agent as root with words checked by
# AgentMessage.run. Mini VM n: gateway veth vg<n> 10.77.<n>.1, pod veth vp<n> 10.77.<n>.2, TPROXY
# port 12000+n (xray-in-vm inbound), relay 127.0.0.1:11000+n in the gateway netns → vsock 2:11000+n.
set -eu
# The agent starts this with an empty environment.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
R=/run/v2mac
CTR=$R/ctr
SECCOMP=/etc/v2mac-seccomp.json
export XDG_RUNTIME_DIR=$R/xdg
asapp() { runuser -u app -- env XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR "$@"; }
gw() { ip netns exec gw "$@"; }
int() { case "$1" in ''|*[!0-9]*) echo "bad number $1"; exit 2;; esac; }
# A store app's root: its own files (unpacked by `load`) over the VM's root, under the container fixes
# in $R/fix, writable on tmpfs like $CTR. Mounted on first use after each boot.
approot() {
  m=$R/app-$1
  [ -d "/data/apps/$1/root" ] || { echo "app $1 is not installed" >&2; exit 2; }
  if ! mountpoint -q "$m"; then
    mkdir -p "$m" "$R/au-$1" "$R/aw-$1"
    mount -t overlay overlay -o "lowerdir=$R/fix:/data/apps/$1/root:/,upperdir=$R/au-$1,workdir=$R/aw-$1" "$m"
    # The app's files could make these symlinks; a root mount would follow them out of $m.
    for d in tmp var/tmp; do
      [ "$(realpath -e "$m/$d" 2>/dev/null)" = "$m/$d" ] || { umount -l "$m"; echo "app $1 replaces /$d" >&2; exit 2; }
      mount -t tmpfs -o mode=1777 tmpfs "$m/$d"
    done
  fi
  echo "$m"
}
# A store app's id (the SHA-256 of its download), "pkgs" for Debian packages (pkg-install), or "-" for
# the VM's own root (sideloads, the terminal), which then has the packages too. The label lets
# pkg-install see that something runs on the packages.
P=/data/apps/pkgs
rootof() {
  case "$1" in
    -) if [ -d $P/root ]; then echo "--label v2mac.pkgs=1 --rootfs $(approot pkgs)"; else echo "--rootfs $CTR"; fi;;
    pkgs) echo "--label v2mac.pkgs=1 --rootfs $(approot pkgs)";;
    *[!0-9a-f]*|'') echo "bad image $1" >&2; exit 2;;
    *) echo "--rootfs $(approot "$1")";;
  esac
}
# Debian's archive for pkg-search and pkg-install: through mini VM <n>'s exit, as root in the container
# (rootless, so `app` here); apt's own _apt user isn't mapped.
# No translated descriptions: they double the lists, which the first search downloads through the exit.
APT="-o APT::Sandbox::User=root -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= -o Acquire::Languages=none"
aptnet() { echo "--network container:vm-$2 -v $R/resolv-$1:/etc/resolv.conf:ro -v $P/lists:/var/lib/apt/lists"; }
# pkglists <n> <id>: Debian's package lists in $P/lists, fetched through mini VM n's exit at most daily
pkglists() {
  install -d -m755 $P; install -d -o app -g app $P/lists
  [ -n "$(find $P/lists -maxdepth 1 -name '*_Packages*' -mmin -1440)" ] && return 0
  # Ends before the helper stops waiting (15 minutes), so a slow exit gets apt's own error back.
  # shellcheck disable=SC2086
  asapp podman run --rm --timeout 600 $HARDENED $(aptnet "$1" "$2") --rootfs $CTR apt-get $APT -q update --error-on=any >$R/pkgs.log 2>&1 \
    || { grep -E "^(W|E):" $R/pkgs.log | head -n 5; tail -n 3 $R/pkgs.log; exit 1; }
}
# Applies one layer tar (OCI whiteouts included) to an app's root, as `app` except for the whiteouts.
apply() {
  root=$2
  tar -tf "$1" | grep -E '(^|/)\.wh\.' > "$1.wh" || true
  while IFS= read -r w; do
    d=$(dirname "$w"); n=$(basename "$w")
    [ "$n" = .wh..wh..opq ] && { echo "opaque directories are not supported"; exit 1; }
    n=${n#.wh.}
    p=$(realpath -m "$root/$d")
    case "$p" in "$root"|"$root"/*) ;; *) echo "bad whiteout $w"; exit 1;; esac
    case "$n" in ''|.|..|*/*) echo "bad whiteout $w"; exit 1;; esac
    rm -rf "${p:?}/$n"; asapp mkdir -p "$p"; mknod "$p/$n" c 0 0
  done < "$1.wh"
  # In a container that sees only this root writable: an earlier layer's symlink can't send a later
  # layer's files out of it.
  # /mnt: the read-only root can't get new mount points.
  asapp podman run --rm -i --network none $HARDENED -v "$root:/mnt" --rootfs $CTR \
    tar -xf - -C /mnt --no-same-owner --exclude='.wh.*' < "$1"
}
# The mini VM's exit facts folder, read-only at /run/v2mac (a folder, so an atomic replace shows through).
facts() { install -d -m755 "$R/facts-$1"; echo "-v $R/facts-$1:/run/v2mac:ro"; }
num() { case "$1" in ''|*[!0-9]*) echo "bad index $1"; exit 2;; esac; [ "$1" -ge 1 ] && [ "$1" -le 250 ] || { echo "bad index $1"; exit 2; }; }
# bridge <dir> <status file> <command>: runs the command (as its own process group) while the app has
# its side of a loopback sound card open, once per use, until <dir> is gone.
# shortcut: polls /proc four times a second (proc files can't be watched); fine for a few open apps.
bridge() {
  pid=""
  while [ -d "$1" ]; do
    if ! grep -qx closed "$2" 2>/dev/null; then
      [ -z "$pid" ] && { setsid sh -c "$3" </dev/null >/dev/null 2>&1 & pid=$!; }
    elif [ -n "$pid" ]; then kill -- "-$pid" 2>/dev/null; pid=""; fi
    sleep 0.25
  done
  [ -n "$pid" ] && kill -- "-$pid" 2>/dev/null
}
# Every container of a mini VM: rootless, no caps, our seccomp (no AF_VSOCK), read-only root.
# `--rootfs $CTR` goes last, before the command: it makes the next word the root path.
HARDENED="--cap-drop=all --security-opt no-new-privileges --security-opt seccomp=$SECCOMP --read-only"

case "$1" in
boot) # boot <unix time>: once per VM boot: the Mac's clock, rootless podman on the data disk, container root, gateway netns
  int "$2"; date -u -s "@$2" >/dev/null
  install -d $R; chmod 711 $R; install -d -o app -g app -m700 $XDG_RUNTIME_DIR
  install -d -o app -g app /data/podman /data/vms /home/app/.config /home/app/.config/containers
  printf '[storage]\ndriver = "overlay"\ngraphroot = "/data/podman/storage"\nrunroot = "%s/storage"\n' $XDG_RUNTIME_DIR \
    > /home/app/.config/containers/storage.conf
  # A writable copy-on-write view of / as container root (crun can't pivot into / itself, M0 0.5).
  # overlayfs takes only the root layer, so /data, /run and the other mounts are not in it.
  mkdir -p $R/cu $R/cw $CTR && mount -t overlay overlay -o lowerdir=/,upperdir=$R/cu,workdir=$R/cw $CTR
  # Empty /tmp and /var/tmp: services' root-only PrivateTmp dirs there stop rootless crun.
  mount -t tmpfs -o mode=1777 tmpfs $CTR/tmp; mount -t tmpfs -o mode=1777 tmpfs $CTR/var/tmp
  chmod 1777 $CTR/run; touch $CTR/run/.containerenv
  # systemd-tmpfiles makes this include at boot; in a rootless container its owner is nobody and ssh refuses it.
  rm -f $CTR/etc/ssh/ssh_config.d/20-systemd-ssh-proxy.conf
  # Each mini VM's Shared folder (helper: virtio-fs tag "shared", one directory per mini VM id).
  mkdir -p /exchange; mount -t virtiofs shared /exchange || echo "no shared folders"
  # What $CTR changes in /, as an overlay layer for store apps' roots (approot).
  install -d -m755 $R/fix $R/fix/etc/ssh/ssh_config.d; install -d -m1777 $R/fix/run; touch $R/fix/run/.containerenv
  mknod $R/fix/etc/ssh/ssh_config.d/20-systemd-ssh-proxy.conf c 0 0
  install -d -m755 /data/apps
  ip netns add gw; gw ip link set lo up
  gw sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv4.ip_forward=0
  # TPROXY'd packets (mark 1) are delivered locally.
  gw ip rule add fwmark 1 lookup 100; gw ip route add local 0.0.0.0/0 dev lo table 100
  ;;
gateway) # gateway <n>...: load rules and xray-in-vm from /run/v2mac, one relay per mini VM
  shift
  gw nft -f $R/gateway.nft
  pkill -f "^xray run -c $R/xray.json" || true
  pkill -f "^socat TCP-LISTEN:11" || true
  # Background jobs call ip directly: a redirected shell function leaves dash's saved copy of the
  # agent's output pipe open in the child, and the agent then waits forever.
  ip netns exec gw setsid xray run -c $R/xray.json >>$R/xray.log 2>&1 </dev/null &
  for n in "$@"; do
    num "$n"
    ip netns exec gw setsid socat TCP-LISTEN:$((11000 + n)),bind=127.0.0.1,reuseaddr,fork VSOCK-CONNECT:2:$((11000 + n)) </dev/null >/dev/null 2>&1 &
  done
  ;;
vm-add) # vm-add <n> <id> <disposable 0|1>: (re)make the mini VM's holder container and its veth
  num "$2"; n=$2; id=$3
  asapp podman rm -f -t0 "vm-$id" >/dev/null 2>&1 || true
  ip -n gw link del "vg$n" 2>/dev/null || true
  install -d -o app -g app -m700 "/data/vms/$id" "/data/vms/$id/home"
  printf 'nameserver 10.77.%s.1\n' "$n" > "$R/resolv-$n"; chmod 644 "$R/resolv-$n"
  if [ "$4" = 1 ]; then home="--mount type=tmpfs,destination=/root"; else home="-v /data/vms/$id/home:/root"; fi
  asapp podman run -d --name "vm-$id" --network none $HARDENED $home -v "$R/resolv-$n:/etc/resolv.conf:ro" --rootfs $CTR sleep infinity >/dev/null
  pid=$(asapp podman inspect -f '{{.State.Pid}}' "vm-$id")
  # The pod makes its own netns (rootless can't join a root-made one); the gateway moves the veth in.
  ip link add "vg$n" type veth peer name "vp$n"
  ip link set "vg$n" netns gw
  ip link set "vp$n" netns "/proc/$pid/ns/net"
  gw ip addr add "10.77.$n.1/30" dev "vg$n"; gw ip link set "vg$n" up
  nsenter -t "$pid" -n sh -c "sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
    ip link set lo up; ip addr add 10.77.$n.2/30 dev vp$n; ip link set vp$n up; ip route add default via 10.77.$n.1"
  ;;
vm-del) # vm-del <n> <id>: stop the mini VM and delete its data
  num "$2"
  asapp podman ps -aq --filter "label=v2mac.vm=$3" | xargs -r runuser -u app -- env XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR podman rm -f -t0 >/dev/null
  asapp podman rm -f -t0 "vm-$3" >/dev/null 2>&1 || true
  ip -n gw link del "vg$2" 2>/dev/null || true
  rm -rf "/data/vms/$3"
  ;;
wipe) # wipe <id>: empty the mini VM's home
  find "/data/vms/$2/home" -mindepth 1 -delete
  ;;
clone) # clone <from> <to>: copy a mini VM's data before vm-add of the copy
  install -d -o app -g app -m700 "/data/vms/$3"
  cp -a "/data/vms/$2/home" "/data/vms/$3/"
  ;;
app) # app <n> <id> <plugin> <disposable 0|1> <ssh-agent vsock port|0> <image id|->: a plugin's launch command in mini VM n on
  # this tty (the agent's pty), from $R/plugin-<id>-<plugin>.argv and .env (written by `put` just before)
  num "$2"; n=$2; id=$3; p=$4; root=$(rootof "$7")
  if [ "$5" = 1 ]; then home="--mount type=tmpfs,destination=/root"; else home="-v /data/vms/$id/home:/root"; fi
  chown app "$R/plugin-$id-$p.env"
  ssh=""
  int "$6"
  if [ "$6" != 0 ]; then
    # Only this app's container sees the socket; the Mac listens on this app's own port while it is open.
    sock=$R/ssh-$$.sock
    socat UNIX-LISTEN:$sock,fork,user=app,mode=600 VSOCK-CONNECT:2:$6 </dev/null >/dev/null 2>&1 &
    trap "kill $! 2>/dev/null; rm -f $sock" EXIT HUP TERM
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$sock" ] && break; sleep 0.1; done
    ssh="-v $sock:/run/ssh-agent.sock -e SSH_AUTH_SOCK=/run/ssh-agent.sock"
  fi
  # xargs appends the plugin's command after --rootfs; with -a the tty stays on stdin.
  # shellcheck disable=SC2086
  xargs -0 -a "$R/plugin-$id-$p.argv" runuser -u app -- env XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR podman run --rm -it \
    --label "v2mac.vm=$id" --network "container:vm-$id" $HARDENED $home $ssh -e TERM=xterm-256color \
    --env-file "$R/plugin-$id-$p.env" -v "$R/resolv-$n:/etc/resolv.conf:ro" $(facts "$id") -w /root $root
  ;;
gui) # gui <token> <n> <id> <plugin> <disposable> <shared> <clipboard> <sound port|0> <microphone port|0> <width> <height> <scale> <image id|->:
  # a window app under sway, served by wayvnc on $R/gui-<token>/vnc.sock (the agent's session connects there)
  int "$2"; t=$2; shift; num "$2"; n=$2; id=$3; p=$4; int "$8"; int "$9"; int "${10}"; int "${11}"; int "${12}"; root=$(rootof "${13}")
  if [ "$5" = 1 ]; then home="--mount type=tmpfs,destination=/root"; else home="-v /data/vms/$id/home:/root"; fi
  shared=""; [ "$6" = 1 ] && [ -d "/exchange/$id" ] && shared="-v /exchange/$id:/root/Shared"
  d=$R/gui-$t; install -d -o app -g app -m700 "$d"
  # Sound (plan "Audio"): the app gets its own loopback card as card 0, only the granted sides. The VM has
  # no Mac sound device: while the app has a side open, bridge carries it to the helper's port for it,
  # which asks the user before it plays anything or opens the Mac's microphone.
  sound=""; c=""
  if [ "$8" != 0 ] || [ "$9" != 0 ]; then
    for c in 0 1 2 3 4 5 6 7; do mkdir "$R/card-$c" 2>/dev/null && { echo "$t" > "$R/card-$c/token"; break; }; c=""; done
    [ -z "$c" ] && echo "no free sound card for $p" >&2
  fi
  if [ -n "$c" ]; then
    sound="--device /dev/snd/controlC$c:/dev/snd/controlC0 --device /dev/snd/timer"
    if [ "$8" != 0 ]; then
      sound="$sound --device /dev/snd/pcmC${c}D0p:/dev/snd/pcmC0D0p"
      bridge "$d" "/proc/asound/card$c/pcm0p/sub0/status" \
        "arecord -q -D hw:$c,1 -f S16_LE -r 48000 -c 2 -t raw | socat -u - VSOCK-CONNECT:2:$8" &
    fi
    if [ "$9" != 0 ]; then
      sound="$sound --device /dev/snd/pcmC${c}D0c:/dev/snd/pcmC0D0c"
      bridge "$d" "/proc/asound/card$c/pcm0c/sub0/status" \
        "socat -u VSOCK-CONNECT:2:$9 - | aplay -q -D hw:$c,1 -f S16_LE -r 48000 -c 2 -t raw" &
    fi
  fi
  chown app "$R/plugin-$id-$p.env"
  # MOZ_ASSUME_USER_NS=0: Firefox's tabs can't make a user namespace here (uid_map EPERM) and would crash.
  # shellcheck disable=SC2086
  xargs -0 -a "$R/plugin-$id-$p.argv" runuser -u app -- env XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR podman run --rm --name "gui-$t" \
    --label "v2mac.vm=$id" --network "container:vm-$id" $HARDENED $home $shared $sound -v "$d:/run/vnc" \
    -e XDG_RUNTIME_DIR=/run/vnc -e WLR_BACKENDS=headless -e WLR_RENDERER=pixman -e WLR_LIBINPUT_NO_DEVICES=1 -e LANG=C.UTF-8 -e MOZ_ASSUME_USER_NS=0 \
    --env-file "$R/plugin-$id-$p.env" -v "$R/resolv-$n:/etc/resolv.conf:ro" $(facts "$id") -w /root $root \
    sh -c 'sway -c /etc/v2mac/sway.conf >/run/vnc/sway.log 2>&1 & sway=$!
      for _ in $(seq 100); do for w in /run/vnc/wayland-*; do [ -S "$w" ] && break 2; done; sleep 0.1; done
      export WAYLAND_DISPLAY=${w##*/}; echo "$WAYLAND_DISPLAY" > /run/vnc/display
      wlr-randr --output HEADLESS-1 --custom-mode "$0" --scale "$1"; shift
      # pipewire-pulse: most apps (Chromium too) play and record through PulseAudio.
      if [ -d /dev/snd ]; then pipewire & sleep 0.3; wireplumber & pipewire-pulse & fi
      wayvnc --unix-socket /run/vnc/vnc.sock & "$@"
      # An app can start a new process of itself and exit (Firefox does on some starts): the session lasts
      # while any process runs but sway, wayvnc and the sound ones.
      while pgrep -v -x "sh|sleep|sway|wayvnc|pipewire|wireplumber|pipewire-pulse" >/dev/null; do sleep 1; done
      kill $sway' "${10}x${11}" "${12}" >"$d.log" 2>&1
  ;;
gui-type) # gui-type <token>: types stdin into the window app (text RFB keysyms can't carry)
  int "$2"
  asapp podman exec -i -e XDG_RUNTIME_DIR=/run/vnc -e LANG=C.UTF-8 "gui-$2" sh -c 'WAYLAND_DISPLAY=$(cat /run/vnc/display) exec wtype -' 
  ;;
gui-size) # gui-size <token> <width> <height> <scale>: the window was resized
  int "$2"; int "$3"; int "$4"; int "$5"
  asapp podman exec -e XDG_RUNTIME_DIR=/run/vnc "gui-$2" sh -c \
    'WAYLAND_DISPLAY=$(cat /run/vnc/display) exec wlr-randr --output HEADLESS-1 --custom-mode "$0" --scale "$1"' "${3}x${4}" "$5"
  ;;
gui-stop) # gui-stop <token>
  int "$2"
  asapp podman rm -f -t0 "gui-$2" >/dev/null 2>&1 || true
  rm -rf "$R/gui-$2" "$R/gui-$2.log"
  for f in "$R"/card-*/token; do [ "$(cat "$f" 2>/dev/null)" = "$2" ] && rm -rf "${f%/token}"; done
  ;;
exit-facts) # exit-facts <id>: $R/exit-<id>.json becomes /run/v2mac/exit.json in that mini VM's apps (atomic rename)
  d=$R/facts-$2; install -d -m755 "$d"; chmod 644 "$R/exit-$2.json"; mv "$R/exit-$2.json" "$d/exit.json"
  ;;
load) # load <sha256>: a store app V2Mac downloaded (gzipped tar of its own layers 0.tar, 1.tar, … on
  # top of the base, which is this root), unpacked once into /data/apps/<sha256>; prints that id
  case "$2" in *[!0-9a-f]*|'') echo "bad layer"; exit 2;; esac
  a=/data/apps/$2
  if [ ! -d "$a/root" ]; then
    rm -rf "$a.new"; install -d -o app -g app "$a.new" "$a.new/root" "$a.new/layers"
    tar -tzf "/exchange/_cache/$2" | grep -qvxE '[0-9]{1,3}\.tar' && { echo "unexpected file in the archive"; exit 1; }
    asapp tar -xzf "/exchange/_cache/$2" -C "$a.new/layers" --no-same-owner
    # Only regular files: a 0.tar symlink would make apply read another app's files.
    [ -z "$(find "$a.new/layers" -mindepth 1 ! -type f)" ] || { echo "unexpected file in the archive"; exit 1; }
    for n in $(ls "$a.new/layers" | sort -n); do apply "$a.new/layers/$n" "$a.new/root"; done
    rm -rf "$a.new/layers"; mv "$a.new" "$a"
  fi
  echo "$2"
  ;;
rmi) # rmi <id>: a store app's files, once no mini VM has it (the helper checks)
  case "$2" in *[!0-9a-f]*|'') exit 2;; esac
  umount -l "$R/app-$2" 2>/dev/null || true # detaches its tmpfs mounts too
  rm -rf "/data/apps/$2" "$R/au-$2" "$R/aw-$2" "$R/app-$2"
  ;;
pkg-search) # pkg-search <n> <id> <word>...: Debian packages matching every word, "name - summary" per line (400 at
  # most, the helper ranks them)
  num "$2"; n=$2; id=$3; shift 3
  pkglists "$n" "$id"
  # shellcheck disable=SC2086
  asapp podman run --rm --network none $HARDENED -v $P/lists:/var/lib/apt/lists:ro --rootfs $CTR apt-cache $APT search -- "$@" \
    >$R/pkgs.out 2>&1 || { tail -n 5 $R/pkgs.out; exit 1; }
  # apt's warnings (lists it can't use) instead of an empty list that looks like "no such program"
  if ! grep -qE '^[a-z0-9][a-z0-9.-]* - ' $R/pkgs.out && grep -qE '^(W|E):' $R/pkgs.out; then
    grep -E '^(W|E):' $R/pkgs.out | head -n 5; ls $P/lists; exit 1
  fi
  if grep -qE '^[a-z0-9][a-z0-9.-]* - ' $R/pkgs.out; then
    grep -E '^[a-z0-9][a-z0-9.-]* - ' $R/pkgs.out | head -n 400
  else
    # Nothing found: what the helper logs, so an empty answer can be told from broken lists.
    { ls -la $P/lists; tail -n 5 $R/pkgs.out; tail -n 5 $R/pkgs.log 2>/dev/null; } | sed 's/^/# /'
  fi
  ;;
pkg-install) # pkg-install <n> <id> <package>: installs a Debian package and what it needs into the shared package
  # root ($P/root, the upper layer of an overlay on /, later a lower layer for apps), through mini VM n's
  # exit; prints "app <gui|pty> <desktop file> <Name> <Exec>" (tab-separated) per window app it brings
  num "$2"; n=$2; id=$3
  case "$4" in ''|-*|*[!a-z0-9.-]*) echo "bad package $4"; exit 2;; esac
  [ -z "$(asapp podman ps -q --filter label=v2mac.pkgs=1)" ] || { echo "busy"; exit 3; }
  pkglists "$n" "$id"
  # dpkg must own the base's files (root's), which the rootless `app` can't. So root's podman runs it, but
  # in a user namespace of its own (300000 on, in the `containers` range): its root is nobody in the VM.
  # overlayfs can't be idmapped, so its lower layers are: the VM's erofs root (/ itself is an overlay)
  # and the fixes, where root's files show as 300000's. The upper layer is plain, with 300000's files.
  install -d -m755 -o 300000 -g 300000 $P/root; install -d -m700 $P/work $P/podman
  # inner:outer, as in uid_map: the disk's 0 shows as 300000
  map=X-mount.idmap=0:300000:65536
  mkdir -p $R/pkgs-base $R/pkgs-fix
  mountpoint -q $R/pkgs-base || mount -t erofs -o "ro,$map" /dev/vda $R/pkgs-base
  mountpoint -q $R/pkgs-fix || mount --bind -o "$map" $R/fix $R/pkgs-fix
  # The apps' view of the packages is remounted on next use, after this changed its layer.
  m=$R/app-pkgs; if mountpoint -q $m; then umount $m/tmp $m/var/tmp $m; fi
  a=$R/pkgs-apt; mkdir -p $a; if mountpoint -q $a; then umount -l $a; fi
  mount -t overlay overlay -o "lowerdir=$R/pkgs-fix:$R/pkgs-base,upperdir=$P/root,workdir=$P/work" $a
  # Not $HARDENED: dpkg needs the namespaced capabilities and a writable root. Its scripts run only here,
  # on the mini VM's network; the lists stay read-only.
  pid=$(asapp podman inspect -f '{{.State.Pid}}' "vm-$id")
  status=0
  # shellcheck disable=SC2086
  # Its own storage on the data disk, root's: overlayfs can't hold podman's storage on the VM's overlay root.
  podman --root $P/podman --runroot $R/pkgs-podman run --rm --uidmap 0:300000:65536 --gidmap 0:300000:65536 --security-opt no-new-privileges --security-opt seccomp=$SECCOMP \
    --network "ns:/proc/$pid/ns/net" -v "$R/resolv-$n:/etc/resolv.conf:ro" -v $P/lists:/var/lib/apt/lists:ro \
    -e DEBIAN_FRONTEND=noninteractive --tmpfs /tmp:rw,exec,mode=1777 --tmpfs /var/tmp:rw,exec,mode=1777 \
    --rootfs "$a" sh -c '
      mkdir -p /var/cache/apt/archives/partial # the rootfs ships without the apt cache
      apt-get $1 -o Debug::NoLocking=true -q install -y --no-install-recommends "$0" && rm -rf /var/cache/apt/archives || exit 1
      for f in $(dpkg -L "$0" | grep "^/usr/share/applications/[^/]*\.desktop$"); do
        awk -F= -v f="${f##*/}" '\''/^\[/ { s = $0 == "[Desktop Entry]" }
          s && $1 == "Name" && n == "" { n = substr($0, 6) }
          s && $1 == "Exec" && e == "" { e = substr($0, 6) }
          s && $1 == "NoDisplay" { h = $2 } s && $1 == "Terminal" { t = $2 } s && $1 == "Type" { y = $2 }
          END { if (y == "Application" && h != "true" && n != "" && e != "") printf "@@app\t%s\t%s\t%s\t%s\n", t == "true" ? "pty" : "gui", f, n, e }'\'' "$f"
      done' "$4" "$APT" >$R/pkgs.log 2>&1 || status=$?
  umount $a
  [ $status = 0 ] || { tail -n 8 $R/pkgs.log; exit 1; }
  sed -n 's/^@@//p' $R/pkgs.log
  ;;
probe) # probe <n> <id> <other n> <other id>: leak probes from mini VM n (plan §9)
  num "$2"; num "$4"
  # a listener in the other mini VM that the probe must not reach
  asapp podman run -d --rm --name "probe-target-$5" --label "v2mac.vm=$5" --network "container:vm-$5" $HARDENED --rootfs $CTR \
    socat TCP-LISTEN:7777,fork SYSTEM:'echo reached' >/dev/null
  asapp podman run --rm --label "v2mac.vm=$3" --network "container:vm-$3" $HARDENED -v "$R/resolv-$2:/etc/resolv.conf:ro" --rootfs $CTR \
    bash /usr/local/lib/v2mac/probe.sh "$2" "$4" || true
  asapp podman rm -f -t0 "probe-target-$5" >/dev/null 2>&1 || true
  ;;
*) echo "unknown command $1"; exit 2 ;;
esac
