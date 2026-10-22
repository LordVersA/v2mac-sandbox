#!/bin/sh
# Spike 0.8: one interactive session (Firefox kiosk, 2x) for trying input by hand.
say() { echo "S08 $*" > /dev/hvc0; }
export XDG_RUNTIME_DIR=/run/user/1000; install -d -o app -g app -m700 $XDG_RUNTIME_DIR
rm -f /run/vnc/vnc.sock; install -d -o app -m755 /run/vnc
runuser -u app -- env XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
  cage -- sh -c "wlr-randr --output HEADLESS-1 --custom-mode 2560x1600 --scale 2; wayvnc --unix-socket /run/vnc/vnc.sock & exec firefox-esr --kiosk file:///usr/local/share/input.html" >/tmp/cage-input.log 2>&1 &
for i in $(seq 30); do [ -S /run/vnc/vnc.sock ] && break; sleep 1; done
chmod 666 /run/vnc/vnc.sock; sleep 6; say "ready input-2x"
