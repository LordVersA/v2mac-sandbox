#!/bin/sh
# Spike 0.7: cage (headless, pixman) + wayvnc on a Unix socket, per phase: hello-gui / heavy page at 1x and 2x.
# The host's RFB client connects when it sees "S07 ready <phase>", and the guest reports CPU while it watches.
say() { echo "S07 $*" > /dev/hvc0; }
export XDG_RUNTIME_DIR=/run/user/1000; install -d -o app -g app -m700 $XDG_RUNTIME_DIR
phase() { # name, mode, scale, app...
  name=$1 mode=$2 scale=$3; shift 3
  rm -f /run/vnc/vnc.sock; install -d -o app -m755 /run/vnc
  runuser -u app -- env XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
    cage -- sh -c "wlr-randr --output HEADLESS-1 --custom-mode $mode --scale $scale; wayvnc --unix-socket /run/vnc/vnc.sock & exec $*" >/tmp/cage-$name.log 2>&1 &
  for i in $(seq 30); do [ -S /run/vnc/vnc.sock ] && break; sleep 1; done
  chmod 666 /run/vnc/vnc.sock 2>/dev/null
  sleep 6; say "ready $name"
  sleep 4; say "cpu $name: $(top -b -w 200 -d 10 -n 2 | awk '/^top/{n++} n==2 && $1 ~ /^[0-9]+$/ && $9+0>0.5 {printf "%s=%s%% ", $12, $9}')"
  say "end $name"; sleep 3
  say "cage log $name: $(grep -iE "error|fail" /tmp/cage-$name.log | head -3 | tr '\n' ' ')"
  pkill -u app cage; sleep 2
}
phase hello-1x 1280x800 1 zenity --info --text=hello-gui
phase heavy-1x 1280x800 1 firefox-esr --kiosk file:///usr/local/share/heavy.html
phase heavy-2x 2560x1600 2 firefox-esr --kiosk file:///usr/local/share/heavy.html
say done
