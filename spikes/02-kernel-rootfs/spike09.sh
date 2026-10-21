#!/bin/sh
# Spike 0.9: virtio-sound card + PipeWire playback. Reports on hvc0.
say() { echo "S09 $*" > /dev/hvc0; }
say "cards: $(cat /proc/asound/cards | tr '\n' ' ')"
export XDG_RUNTIME_DIR=/run/pw; mkdir -p $XDG_RUNTIME_DIR
pipewire >/tmp/pw.log 2>&1 & sleep 1
wireplumber >/tmp/wp.log 2>&1 & sleep 3
say "sinks: $(wpctl status 2>&1 | sed -n '/Sinks:/,/Sources:/p' | tr '\n' ' ' | tr -s ' ')"
wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.2
speaker-test -D pipewire -c 1 -t sine -f 440 -l 1 >/tmp/st.log 2>&1 & st=$!
sleep 1; say "pcm while playing: $(grep -E 'state|hw_ptr' /proc/asound/card0/pcm0p/sub0/status | tr '\n' ' ')"
sleep 1; say "pcm a second later: $(grep -E 'hw_ptr' /proc/asound/card0/pcm0p/sub0/status | tr '\n' ' ')"
wait $st; say "speaker-test rc=$? $(tail -2 /tmp/st.log | tr '\n' ' ')"
say done
