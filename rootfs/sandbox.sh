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
num() { case "$1" in ''|*[!0-9]*) echo "bad index $1"; exit 2;; esac; [ "$1" -ge 1 ] && [ "$1" -le 250 ] || { echo "bad index $1"; exit 2; }; }
# Every container of a mini VM: rootless, no caps, our seccomp (no AF_VSOCK), read-only root.
# `--rootfs $CTR` goes last, before the command: it makes the next word the root path.
HARDENED="--cap-drop=all --security-opt no-new-privileges --security-opt seccomp=$SECCOMP --read-only"

case "$1" in
boot) # once per VM boot: rootless podman on the data disk, container root, gateway netns
  install -d $R; chmod 711 $R; install -d -o app -g app -m700 $XDG_RUNTIME_DIR
  install -d -o app -g app /data/podman /data/vms /home/app/.config /home/app/.config/containers
  printf '[storage]\ndriver = "overlay"\ngraphroot = "/data/podman/storage"\nrunroot = "%s/storage"\n' $XDG_RUNTIME_DIR \
    > /home/app/.config/containers/storage.conf
  # A writable copy-on-write view of / as container root (crun can't pivot into / itself, M0 0.5).
  # overlayfs takes only the root layer, so /data, /run and the other mounts are not in it.
  mkdir -p $R/cu $R/cw $CTR && mount -t overlay overlay -o lowerdir=/,upperdir=$R/cu,workdir=$R/cw $CTR
  chmod 1777 $CTR/run $CTR/tmp; touch $CTR/run/.containerenv
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
