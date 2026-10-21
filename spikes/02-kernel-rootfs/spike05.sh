#!/bin/sh
# Spike 0.5: pods in a root-made netns, and seccomp against AF_VSOCK. Reports on hvc0.
say() { echo "S05 $*" > /dev/hvc0; }
ip netns add podA && ip link add vA type veth peer name vA-pod && ip link set vA-pod netns podA
mount -t tmpfs tmpfs /var/lib/containers
install -d -o app -g app /home/app/.local/share/containers && mount -t tmpfs -o uid=1000,gid=1000 tmpfs /home/app/.local/share/containers
# a writable copy-on-write view of / as the container rootfs (crun can't pivot into / itself)
mkdir -p /tmp/cu /tmp/cw /tmp/cr && mount -t overlay overlay -o lowerdir=/,upperdir=/tmp/cu,workdir=/tmp/cw /tmp/cr
X=/tmp/xdg-app; install -d -o app -g app -m700 $X
asapp() { runuser -u app -- env XDG_RUNTIME_DIR=$X "$@"; }
N="--network ns:/run/netns/podA"
chmod 1777 /tmp/cr/run
say "rootless join root netns: $(asapp podman run --rm $N --rootfs /tmp/cr ip -o link 2>&1 | tr '\n' ' ')"
say "rootful userns=auto join: $(podman run --rm $N --userns=auto --rootfs /tmp/cr ip -o link 2>&1 | tr '\n' ' ')"
say "hardened: $(podman run --rm $N --userns=auto --cap-drop=all --security-opt no-new-privileges --read-only --memory 64m --rootfs /tmp/cr sh -c 'cat /proc/self/uid_map; cat /sys/fs/cgroup/memory.max' 2>&1 | tr '\n' ' ')"
say "vsock default seccomp: $(podman run --rm --network none --userns=auto --rootfs /tmp/cr /usr/local/bin/agent 2>&1 | tr '\n' ' ')"
say "vsock v2mac seccomp: $(podman run --rm --network none --userns=auto --security-opt seccomp=/etc/v2mac-seccomp.json --rootfs /tmp/cr /usr/local/bin/agent 2>&1 | tr '\n' ' ')"
say "rootless vsock v2mac seccomp: $(asapp podman run --rm --network none --security-opt seccomp=/etc/v2mac-seccomp.json --rootfs /tmp/cr /usr/local/bin/agent 2>&1 | tr '\n' ' ')"
# rootless pod makes its own netns; root (the gateway) moves the veth in from outside
ip link add vB type veth peer name vB-pod
asapp podman run -d --name podB --network none --cap-drop=all --security-opt seccomp=/etc/v2mac-seccomp.json --rootfs /tmp/cr sleep 60 >/dev/null 2>&1
pid=$(asapp podman inspect -f '{{.State.Pid}}' podB 2>&1)
ip link set vB-pod netns "$pid" && nsenter -t "$pid" -n sh -c 'ip addr add 10.77.2.2/30 dev vB-pod; ip link set vB-pod up; ip route add default via 10.77.2.1'
say "rootless own netns + veth moved in by root (pid $pid): $(asapp podman exec podB sh -c 'ip -o -4 addr; ip route' 2>&1 | tr '\n' ' ')"
say "rootless pod can't touch it: $(asapp podman exec podB ip link set vB-pod down 2>&1 | tr '\n' ' ')"
echo +memory +pids > /sys/fs/cgroup/cgroup.subtree_control; mkdir /sys/fs/cgroup/podB
echo 64M > /sys/fs/cgroup/podB/memory.max; echo 50 > /sys/fs/cgroup/podB/pids.max
for t in $(cat /proc/$pid/task/*/children 2>/dev/null) $pid; do echo $t > /sys/fs/cgroup/podB/cgroup.procs; done
say "root-set cgroup on rootless pod: $(asapp podman exec podB sh -c 'cat /proc/self/cgroup; cat /sys/fs/cgroup/memory.max 2>/dev/null' 2>&1 | tr '\n' ' ') limits $(cat /sys/fs/cgroup/podB/memory.max) $(cat /sys/fs/cgroup/podB/pids.max)"
touch /tmp/cr/run/.containerenv; chown app /tmp/cr/run/.containerenv
say "pod pid cgroup seen by root: $(cat /proc/$pid/cgroup)"
mkdir /sys/fs/cgroup/deleg; chown -R app:app /sys/fs/cgroup/deleg
say "rootless --memory in delegated cgroup: $(sh -c 'echo $$ > /sys/fs/cgroup/deleg/cgroup.procs; runuser -u app -- env XDG_RUNTIME_DIR='$X' podman run --rm --network none --memory 64m --pids-limit 50 --rootfs /tmp/cr sh -c "cat /proc/self/cgroup; cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/pids.max"' 2>&1 | tr '\n' ' ')"
say "rootless hardened: $(asapp podman run --rm --network none --cap-drop=all --security-opt no-new-privileges --read-only --security-opt seccomp=/etc/v2mac-seccomp.json --rootfs /tmp/cr sh -c 'grep -E "CapEff|NoNewPrivs" /proc/self/status; touch /x' 2>&1 | tr '\n' ' ')"
say "seccomp status rootless v2mac: $(asapp podman run --rm --network none --security-opt seccomp=/etc/v2mac-seccomp.json --rootfs /tmp/cr grep Seccomp /proc/self/status 2>&1 | tr '\n' ' ')"
say "profile head: $(head -c 300 /etc/v2mac-seccomp.json)"
say done
