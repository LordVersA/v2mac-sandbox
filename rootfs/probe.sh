#!/bin/bash
# Leak probes (plan §9), run in a hardened container of mini VM $1; $2 is another mini VM's index.
# One line per check: "PASS <name> [detail]" or "FAIL <name> [detail]". Host-level checks (tcpdump on
# the Mac's NIC) are not here.
n=$1 other=$2
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; }
quiet() { timeout "${T:-8}" bash -c "$1" >/dev/null 2>&1; }

# Through the exit: plain HTTP to an IP echo service, by name (resolved by the gateway's fake DNS).
ip=$(timeout 20 bash -c 'exec 3<>/dev/tcp/api.ipify.org/80; printf "GET / HTTP/1.0\r\nHost: api.ipify.org\r\n\r\n" >&3; tail -n1 <&3' 2>/dev/null)
[[ $ip =~ ^[0-9.]+$|: ]] && pass "exit $ip" || fail exit "no answer through the exit"

# Names resolve to the fake DNS pool, also when asking 8.8.8.8 directly: no real resolver is reachable.
a=$(getent ahostsv4 example.com | awk 'NR==1{print $1}')
[[ $a == 198.1[89].* ]] && pass "dns fake $a" || fail dns "resolved to ${a:-nothing}"
q='\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01'
ans=$(printf "$q" | timeout 8 socat -t5 - UDP:8.8.8.8:53 2>/dev/null | od -An -tu1 | tr -s ' \n' ' ')
[[ -z $ans || $ans == *" 4 198 1"[89]" "* ]] && pass "dns-8.8.8.8 ${ans:+fake answer}" || fail dns-8.8.8.8 "real answer: $ans"

# No IPv6 at all.
[[ -z $(ip -6 addr show scope global 2>/dev/null) ]] && ! quiet 'exec 3<>/dev/tcp/2606:4700:4700::1111/443' \
  && pass ipv6 || fail ipv6 "an IPv6 address or route exists"

# ICMP is dropped.
! T=6 quiet 'ping -c1 -W3 1.1.1.1' && pass icmp || fail icmp "ping answered"

# Other mini VMs and the gateway: a listener there must not be reached. TPROXY takes every
# connection, so only data coming back counts.
for t in 10.77.$other.2 10.77.$other.1 10.77.$n.1; do
  got=$(timeout 6 socat -T4 - TCP:$t:7777 </dev/null 2>/dev/null)
  [[ $got == *reached* ]] && fail "reach $t" "answered" || pass "reach $t"
done

# Routes, links and firewall stay out of reach.
quiet "ip route add 1.2.3.4/32 dev vp$n" && fail route "route added" || pass route
quiet "ip link set vp$n down" && fail link "link changed" || pass link
quiet "nft list ruleset" && fail nft "nft readable" || pass nft

# AF_VSOCK is denied by seccomp (EPERM), so the host's vsock ports are unreachable.
err=$(timeout 5 socat -T3 - VSOCK-CONNECT:2:1024 </dev/null 2>&1)
[[ $err == *"not permitted"* ]] && pass vsock || fail vsock "${err:0:80}"
