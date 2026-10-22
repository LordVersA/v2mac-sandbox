# V2Mac Secure Sandbox — Implementation Plan (no code yet)

## Context
Opt-in **Secure Sandbox**: the user adds **mini VMs**, installs apps into each, and every app shows on
macOS as **its own Mac app** (own window, Dock icon, ⌘-Tab entry, "V2Mac Protected" badge). Each mini
VM has its own Xray exit, is fail-closed and is separate from every other mini VM. The user never sees
a Linux desktop.

**V2Mac.app contains no sandbox code.** Users who never open the sandbox download nothing. The first
click on "Sandbox" downloads the sandbox (helper + VM image), and from then on the helper owns the
Sandbox window and everything behind it. The sandbox v1 is **the platform only**: runtime, mini VMs,
per-VM exits, display bridges, trust chain, mini store, plugin API v1. Firefox, Chromium, Terminal,
SSH, RDP… are **separate plugin repos** built later; two tiny sample plugins prove the platform.

### Decisions (grills of 2026-10-22)
| Topic | Decision |
|---|---|
| Packaging | A **helper process** ("V2Mac Sandbox", an ad-hoc signed app bundle) downloaded into `<data>/sandbox/`. Not a loadable bundle: V2Mac has Hardened Runtime, and loading a separately downloaded bundle into an ad-hoc app would need `disable-library-validation`. |
| Versions | **Locked**: each V2Mac release pins one sandbox version by SHA-256. The pin is the trust; the sandbox download needs no key of its own. |
| V2Mac ↔ helper | V2Mac checks the helper's hash, launches it and hands it one end of a **socketpair**. No listening socket exists, so no other process can ask for server configs. |
| Sandbox core | The **helper** runs its own xray (V2Mac's bundled binary) through `CoreRunner`. V2Mac gives it ready outbounds over the link. Secrets stay on the host, never in the VM. |
| Quit | Quitting V2Mac with sandbox apps open asks: quit them too, or cancel. The helper never outlives V2Mac. |
| Downloads | Helper, image and plugin layers all go through V2Mac's `FetchRoute` order (proxy if connected, else direct), with resume. Hashes make the route irrelevant to trust. |
| Entry | "Sandbox" in the menu bar panel and the main window toolbar. First click: a sheet (what it is, size, RAM) with Download; then it opens the Sandbox window. Settings → Sandbox: RAM cap, Remove. |
| Remove | One confirm deletes helper, image, data disk (all mini VMs), layer cache and the generated apps. Shared folders are listed and kept unless ticked. |
| Mini VM | A container group (one Podman pod) inside **one shared hidden Linux VM**, shown to the user as a VM. No merge. |
| Add | **Empty**, **Template** (store list of plugin ids), or **Clone** (apps + data). Layers come from the shared cache or are downloaded. |
| Exit | Picked at creation (default: active server or Fastest), changeable live. When it stops working: blocked, red capsule, one notification with "Switch server". Never switches on its own. |
| Data | Persistent per mini VM; per-VM **Disposable** switch (tmpfs homes) and **Wipe data**. |
| UI | The helper's **Sandbox window**. One Mac app **per app per mini VM** (`Firefox — Work.app`), icon tinted in the VM's colour. |
| Files | Visible `~/V2Mac Sandbox/<VM>/Shared` per VM (= `~/Shared` in its apps). Files written by the VM get `com.apple.quarantine`. |
| Clipboard | Mac→VM only on ⌘V in a sandbox window; VM→Mac on copy. Text + images. Per-VM switch per direction. |
| Terminal/SSH | `pty` plugins open in the Mac's Terminal through a pty bridge over vsock. |
| SSH keys | Mac's ssh-agent forwarded over vsock only while that terminal is open and only if approved. |
| Kernel | **Our own minimal kernel** from the current kernel.org LTS; a weekly CI job builds new point releases, runs boot + leak probes and opens a PR. |
| VM agent | **Swift**, built with the Static Linux SDK; agent protocol types shared with the helper in one package. |
| Repos | One `sandbox` repo (helper, agent, protocol, image build); it uses `../app/Packages/V2MacCore` by path, CI checks out the app at a pinned tag beside it. Plus `store` and `plugin-template`. |
| Store | Separate repo, one `index.json` signed offline **on a Ledger Nano S Plus/X** (Ed25519 via the SSH/PGP Agent app, `ssh-keygen -Y sign`, SSHSIG format; the recovery phrase is the backup). Expires after **90 days**; a GitHub Action opens an issue at 60. |
| Publishing | Release builds install only what the index lists; dev builds can sideload a local plugin folder. Submissions are PRs to the store repo; store CI posts a check report; you review with a checklist, merge, sign. |
| Revocation | `revoked: [{id, version, reason}]` in the index; the sandbox stops that version and offers Update or Remove; data stays. |
| Builds | Each plugin repo's CI builds its OCI layers at a tag; the index pins commit + every layer's SHA-256. |
| SDK | Template repo (0BSD) + base images + docs + samples `hello-gui`, `hello-pty`. Plugins **must** build `FROM` a released base image digest (store CI enforces). |
| Plugin API | Integer `api`, additive only. v1: manifest + launch, display `gui`/`pty`, exit facts, permissions. `settings` reserved for a later api. |
| Display | Software path first (cage + wayvnc + Swift RFB). libkrun GPU spike **only if** M0 misses the target. |
| Resources | RAM cap = ¼ of the Mac's memory (2–8 GB); boot on first app, shut down 5 min after the last; cgroup limits per mini VM. |
| Other VPNs | Later (§10). v1 keeps the gateway's upstream slot generic. |

Everything marked **[verify]** is an unconfirmed assumption; M0 measures it before anything is built on it.

## 1. Where the code lives
| Piece | Repo | Notes |
|---|---|---|
| Sandbox entry, download/verify/launch, link server, outbounds, quit prompt, Settings → Sandbox, notifications | `app` | The only sandbox code in V2Mac; small. |
| Link message types (`SandboxLink`) | `app` package (`V2MacCore/Sandbox/`) | Pure value types, tested; the helper uses them by path. |
| Helper app (VM, vsock, sandbox core, gateway control, RFB client, Sandbox window, stubs, pty bridge, store client) | `sandbox` | SwiftPM + app target; depends on `V2MacCore` by path. |
| VM agent + agent protocol | `sandbox` | Static Linux SDK build. |
| Kernel config, rootfs (mmdebstrap), base images | `sandbox` | Same release as the helper. |
| `index.json`, signing script, review checklist | `store` | |
| Template, samples, plugin docs | `plugin-template` | |

Reused from `V2MacCore` by the helper: `CoreRunner` (+ `replaceOutbound`), `ExitLookup`, `CountryPlaces`,
`JSONValue`. Used inside V2Mac for the link: `ConfigBuilder.proxyOutbound` + `Tun.binding` (ready
outbounds), `FetchRoute`/`BoundedFetch` (downloads), `KillSwitch.allowFile` (V2Mac adds the IPs of
every server it hands out), `NotificationService` (helper events are posted by V2Mac, so Settings →
Notifications keeps one switch per kind).

## 2. V2Mac ↔ helper link
- V2Mac downloads `V2Mac Sandbox.app.zip`, checks the pinned SHA-256, unpacks into `<data>/sandbox/`,
  re-checks the executable's hash before each launch, starts it with one socketpair end as fd 3.
- Messages (length-prefixed JSON, size-limited, fuzz-tested): `servers` / `serversChanged`,
  `outbound(id)` → JSON, `active`, `download(url, sha256)` → file path, `notice(kind, text)`,
  `openWindow`, `quitRequest` → apps open? → answer.
- If the link closes, the helper shuts its apps down (it never runs without V2Mac).
- The helper bundle carries `com.apple.security.virtualization`; V2Mac.app's entitlements don't change.

## 3. Runtime (in `sandbox`)
**Guest: Debian 13 minimal arm64** userland (glibc, so plugin binaries just work). **Kernel: our own**
minimal config from the kernel.org LTS (virtio, vsock, erofs, netns, nftables/TPROXY, user ns,
cgroups v2, overlayfs); weekly CI bump PRs. `VZLinuxBootLoader` wants an uncompressed arm64 `Image`.

**Hypervisor: Apple Virtualization.framework** (in the helper). Devices: virtio-blk ×2 (read-only
rootfs + data disk), virtio-vsock, virtio-fs (`<data>/sandbox/exchange`, holding the `Shared` folders),
virtio-sound, entropy, balloon. **No network device.** VZ has no 3D GPU for Linux guests.

**Agent** (Swift, static): the only process that owns vsock. Creates netns/pods, runs podman, the
gateway relays, VNC and pty forwarding; accepts a fixed message set from the helper only.

**Isolation: rootless Podman + crun, one pod per mini VM.** Every container: user namespace,
`--cap-drop=all`, `no-new-privileges`, read-only rootfs, our seccomp profile (Podman's default with
`socket` narrowed to a family allowlist without AF_VSOCK; the default allows it), cgroup limits set by the
agent from outside (rootless `--memory` is ignored), and the pod's own netns, into which the agent moves
the gateway's veth (rootless can't join a root-made netns). Verified in M0 0.5. The kernel is built
without io_uring and the profile denies it too: `IORING_OP_SOCKET` would open AF_VSOCK past the `socket` rule.

## 4. Network: gateway and per-VM exits
```
Mini VM pod A (netns, 10.77.A.2, only veth, IPv6 off, default route = gateway)
   │ veth
Gateway netns (VM, root, apps can't touch it)
   nftables: default DROP; per-veth TPROXY → xray-in-vm inbound "vm-A" (TCP+UDP); DNS → xray fakedns
   xray-in-vm: inbound vm-A → outbound "host-A" = VLESS-plain to 127.0.0.1:<relay port A>
   relay (agent: TCP → vsock 2:<port A>)
   │ virtio-vsock
Helper: VZVirtioSocketListener port A → 127.0.0.1:<sandbox core inbound vm-A>
Sandbox core (helper's xray, CoreRunner): inbound vm-A (VLESS, per-VM UUID) → outbound vm-A
   outbound vm-A = JSON from V2Mac (proxyOutbound + NIC binding)
```
- Independent of the main connection: works with the main VPN off, on another server, or in TUN mode.
  Exit change = `replaceOutbound(tag: "vm-A")`. Add/remove mini VM = `xray api adi/adrules`
  **[verify in 26.10.21]**, else restart only the sandbox core.
- **Fail closed by construction**: no NIC in the VM. Any piece down → packets have nowhere to go.
  ICMP and other IP protocols dropped, IPv6 off, host resolver never used. QUIC/WebRTC go through
  TPROXY to the same exit.
- Exit down: `ExitLookup` through the VM's path fails → red capsule + `notice(sandboxExitDown)`.
- Kept open for later (§10): the per-VM upstream is "an endpoint over vsock", not one fixed shape.

## 5. Display
- **`gui`**: in the app's container `cage` (wlroots kiosk, headless, pixman) runs only that app;
  `wayvnc` serves it (damage-only, input, clipboard, resize **[verify]**). The agent forwards it over
  vsock. The helper's Swift RFB client (Raw/CopyRect/ZRLE, then Tight-JPEG; parser fuzz-tested)
  draws into a `CALayer`. Xpra, Waypipe, Weston RAIL, `VZVirtualMachineView` rejected.
- **`pty`**: the generated app opens the user's Terminal running the helper's `v2mac-pty`, which
  bridges the pty over a Unix socket → helper → vsock; resize, signals, ssh-agent (if approved).
- **One Mac app per app per mini VM**: `~/Applications/V2Mac Sandbox/<App> — <VM>.app`, a copy of the
  helper's tiny stub with its own `Info.plist` (`io.github.lordversa.v2mac.sandbox.<vm>.<plugin>`)
  and tinted `.icns`, re-signed ad-hoc. The stub owns window, Dock icon and menu; frames come from
  the helper (which boots the VM on demand, asking V2Mac to launch it if needed).
- **Title capsule**: "🛡 V2Mac Protected · <VM> · 🇩🇪 Frankfurt"; red "Not connected" when the exit is down.
- **Input [verify]**: Persian layout keysyms, IME, ⌘→Ctrl, trackpad scroll. **Audio**: virtio-sound +
  PipeWire, per-app mute.
- **Target**: smooth at 2× under ~1 core **[verify]**; plan B 1× + macOS scaling; plan C libkrun spike.

## 6. Plugin API v1
```
api: 1                     # integer, additive only
id, name, version, icon, publisher, source {repo, commit}
from: <base-cli|base-gui digest>                # must be a released base image
layers [{url, sha256, size}]
display: gui | pty
launch {cmd, env}
permissions [clipboard, shared, ssh-agent]      # user approves at install, runtime enforces
settings                                        # reserved, ignored by api 1
changelog, securityNotes
```
The runtime gives every app: `/run/v2mac/exit.json` (country, city, lat/lon, IANA timezone, exit IP;
read-only, replaced atomically, watch with inotify), `TZ` at launch, `~/Shared` (only with `shared`),
a home on the data disk (tmpfs when Disposable). Nothing else: no vsock, nft, other pods or host paths.
Plugins with a newer `api` are hidden with "Update V2Mac"; a breaking change means `api: 2` and
`api: 1` keeps working.

## 7. Store, trust, SDK
- **`store` repo**: `index.json` + `index.json.sig` (SSHSIG, Ed25519, signed on the Ledger;
  public key pinned in the helper, verified with CryptoKit `Curve25519.Signing`). Fields: `version`
  (monotonic, rollback refused), `expires` (90 days; installs/updates blocked after, running plugins
  untouched), `minApi`, `plugins[]` (full manifests, pinned commit + layer hashes), `templates[]`,
  `revoked[]`. Checked when the Sandbox window opens and daily.
- **Submission**: PR adding a plugin repo URL + tag. Store CI downloads the release, checks hashes,
  schema, `api`, `from` digest and permissions, and comments a report. Review at that commit with
  the checklist, merge, sign on the Ledger, push.
- **Install**: layers via the link's `download` (or the shared cache), every SHA-256 checked against the
  signed index, `podman load`. Dev builds also accept a local plugin folder ("Unverified").
- **Verify Installation** per plugin: source + commit, version, hashes, signature, permissions,
  re-hash on demand. "Verified" means "unchanged since published", not "safe".
- **Base images** `base`, `base-cli`, `base-gui` (cage, wayvnc, PipeWire client, fonts, gtk3, mesa
  llvmpipe) are released by `sandbox`.
- **SDK** = `plugin-template` (0BSD): Containerfile, `plugin.json`, icon, CI workflow, docs page,
  samples `hello-gui` (input, resize, clipboard, exit facts) and `hello-pty`.

## 8. Threat model (summary)
| Asset / actor | Threat | Control |
|---|---|---|
| Malicious site → app | escape container | user ns, seccomp, cap drop, ro rootfs, no vsock |
| Compromised app | reach another mini VM, change routes, reach host | own pod netns, nft in gateway netns, AF_VSOCK denied, no host mounts |
| Compromised VM kernel | reach internet directly | no NIC; only vsock ports the helper listens on |
| Compromised VM kernel | reach other mini VMs | **not prevented**: one shared kernel (accepted) |
| Compromised VM | steal server secrets | secrets only in V2Mac and the helper on the host |
| Compromised VM | plant files / read clipboard / use SSH keys | quarantine flag; ⌘V-only paste; agent only during an approved session |
| Compromised VM → host | abuse bridges | helper parses only RFB, pty and fixed agent messages, length-limited, fuzz-tested |
| Other Mac processes | get server configs | socketpair only, no listening socket; helper hash checked before launch |
| Other Mac processes | hijack per-VM inbounds | 127.0.0.1 + per-VM VLESS UUIDs |
| Swapped helper or image | run attacker code | SHA-256 pinned in each V2Mac release |
| Swapped plugin / frozen index | supply chain | Ledger-signed index, version + 90-day expiry, revoked list, per-layer SHA-256, pinned commits, enforced base |
| Network change, sleep, main VPN toggle | direct leak | no direct path exists; sandbox core binds the NIC like the main core |
| Later: L3 VPN adapters (§10) | VPN credentials in the VM | stated in UI; only for those adapters |

## 9. Automated security tests
- **`app` package**: link message parsing (fuzz), outbound handout.
- **`sandbox` package**: agent protocol fuzzing, RFB parser fuzzing, index/manifest parsing,
  SSHSIG/rollback/expiry/revocation/`api` checks, gateway nft + xray config golden tests.
- **In-VM probe container** (needs the runtime): direct TCP/UDP, DNS to 8.8.8.8, IPv6, ICMP, STUN
  public IP ≠ exit IP, reaching another mini VM, nft/route change, `socket(AF_VSOCK)` all fail;
  traffic through the assigned exit works. Run on every kernel bump PR.
- **Host-level**: tcpdump on the physical NIC during probes (only sandbox core → its server IPs);
  kill sandbox core / relay / agent mid-download, swap exit mid-transfer, Wi-Fi change, sleep/wake,
  main VPN and TUN toggles, V2Mac quit (helper and apps stop).
- Reproducible evidence, never a "100% secure" claim.

## 10. Later (not v1)
- **Plugin repos**: Firefox (privacy profile from exit facts: TZ, geolocation in exit city,
  `media.peerconnection.ice.no_host`, fingerprinting protection without forced UTC, telemetry off),
  Chromium, Terminal, SSH, RDP; templates like "Private browsing".
- **Other VPNs as Xray outbounds**: WireGuard needs nothing (Xray's `wireguard` outbound). OpenVPN /
  OpenConnect / IPsec in their own netns in the VM with a tiny SOCKS server, used by the host as a
  `socks` outbound over vsock; then V2Mac's TUN mode, system proxy and kill switch can use them too.
  Cost: those credentials live in the VM.
- GPU rendering (libkrun) if needed; plugin `settings` (api 2); more permissions.

## 11. Milestones (each behind "Sandbox (beta)", dev build first)

### M0 — Spikes
| # | Task | Go | No-go → | Result |
|---|---|---|---|---|
| 0.1 | Ad-hoc signed helper with `com.apple.security.virtualization`, launched by V2Mac, boots a VM | works | sandbox only in Developer ID builds; decide before M1 | **Go** (2026-10-22): V2MacDev → ad-hoc helper → Debian trixie kernel+initrd reaches init in 0.75 s. `spikes/01-adhoc-vz` |
| 0.2 | Own LTS kernel + Debian userland: boot time, idle RAM | < 3 s, < 250 MB | trim config/rootfs | **Go** (2026-10-22): 6.18.58 from `allnoconfig` + fragment (10.4 MB `Image`), trixie minbase+systemd+podman as lz4hc erofs (185 MB); multi-user in 0.40 s, idle 52 MB used + 146 MB cache. `spikes/02-kernel-rootfs` |
| 0.3 | Swift Static Linux SDK agent: size, vsock, netlink/podman calls | < 15 MB, works | Go agent, protocol written twice | **Go** (2026-10-22): Musl-only agent 6.5 MB stripped; vsock listen, raw netlink dump, `posix_spawn` podman all work. Must build in the `swift:6.4.0` container (Xcode's compiler rejects the swift.org SDK). Foundation not yet measured. `spikes/03-static-agent` |
| 0.4 | vsock relay throughput + latency (TCP and UDP-in-VLESS) | ≥ 300 Mbit/s, < 1 ms | tune relay | **Go** for raw vsock (2026-10-22): 29 µs round trip, 3.0 Gbit/s each way duplex. The xray TCP relay and UDP-in-VLESS ride on this; measure them end to end in M2. Second `connect(toPort:)` from inside a connect handler crashes VZ: hop to the main queue. |
| 0.5 | Rootless Podman pods on gateway netns; seccomp denies AF_VSOCK | both | custom profile / bubblewrap | **Go, changed** (2026-10-22): rootless `setns` into a root-made netns is EPERM, so the pod makes its own netns and the agent moves the veth in (pod can't touch it). Podman's default seccomp **allows** AF_VSOCK; our family-allowlist profile denies it. Rootless `--memory` is ignored, so the agent puts the pod in a limited cgroup from outside. Also needed: `pivot_root` init (no user ns in chroot), netavark `firewall_driver=none`, `cgroup_manager=cgroupfs`, `default_sysctls=[]`, storage on the data disk. `spikes/02-kernel-rootfs/spike05.sh` |
| 0.6 | `xray api adi/adrules` in 26.10.21 | exists | restart sandbox core | **Go** (2026-10-22): `adi`, `ado`, `adrules -append` add a working path live; `rmrules`, `rmi`, `rmo` remove it. `spikes/06-xray-api` |
| 0.7 | cage + wayvnc + prototype RFB, `hello-gui` + heavy page, 1× and 2× | smooth 2× < 1 core | 1× + scaling; then libkrun spike | **Go** (2026-10-22): cage (headless, pixman) + wayvnc on a Unix socket → agent → vsock → Swift RFB client (Raw/CopyRect only) → `CALayer`. Static window 0.1 updates/s. Heavy page 1× 29.5 fps, 104 MB/s, guest display path 22 % + host client 11 %; 2× (2560×1600) 30.6 fps, 236 MB/s, guest 56 % + host 28 %: under one core in total, frames checked. Raw is enough over vsock (~3 Gbit/s); ZRLE/Tight only if a 5K screen nears that. libkrun spike not needed. `spikes/02-kernel-rootfs/rfb.swift`, `spike07.sh` |
| 0.8 | Input: Persian, IME, ⌘ mapping, trackpad | usable | extended keysym/text messages |
| 0.9 | virtio-sound + PipeWire | plays | audio after v1 | **Go** (2026-10-22): VZ virtio-sound output → guest `virtio-snd` card; PipeWire + WirePlumber (no D-Bus) play through `pipewire-alsa`, PCM `RUNNING` at ~48k frames/s. `spikes/02-kernel-rootfs/spike09.sh` |
| 0.10 | Generated ad-hoc stubs: launch, own Dock identity, LaunchServices | works | per-window Dock tiles | **Go** (2026-10-22): copies of one stub with their own `Info.plist`, iconset and ad-hoc signature, registered with `lsregister`: separate apps in `lsappinfo`, own tinted Dock tiles, `open -b` finds each. `spikes/10-stubs` |
| 0.11 | pty bridge in Terminal.app + ssh-agent forward | works | own terminal window | **Go** (2026-10-22): Terminal.app → `v2mac-pty` (raw mode; keyboard and resize frames) → Unix socket → helper → vsock → agent `forkpty` bash. Resize 24×80 → 40×120 and Ctrl-C reach the guest; guest `ssh-add -l` and `ssh-keygen -Y sign` use the Mac's agent over vsock 2:1027. `spikes/02-kernel-rootfs/pty.swift` |
| 0.12 | Ledger SSH/PGP Agent app: Ed25519 key, `ssh-keygen -Y sign`, CryptoKit verify | works | Keychain key + paper backup |

*Done when:* results recorded here and every decision confirmed or changed.

### M1 — Link and runtime
1. `sandbox` repo: SwiftPM layout (helper app, agent, protocol), `V2MacCore` by path, CI with the app
   checked out at a pinned tag.
2. `app`: `SandboxLink` types + tests; entry sheet; download (FetchRoute, resume), hash check, unpack,
   launch with socketpair; quit prompt; Settings → Sandbox (RAM cap, Remove); `NotificationKind` cases.
3. Kernel config + weekly LTS bump workflow; mmdebstrap rootfs (erofs); release with hashes.
4. Helper: boot/stop VM, data disk, RAM cap, idle shutdown; agent handshake over vsock.
5. `-debugSandbox install|boot|stop` hooks.
*Done when:* dev V2Mac downloads a locally served sandbox, boots the VM, and Remove frees all disk.

### M2 — Mini VMs, gateway, exits
1. Gateway nft + in-VM xray config, sandbox core config (golden tests).
2. Sandbox core via `CoreRunner`; outbounds from the link; V2Mac adds handed-out server IPs to the kill switch.
3. Gateway netns, pods, TPROXY, fakedns, relays.
4. Mini VM model: Empty / Clone / Wipe / Delete / Disposable.
5. Exit picker, live swap, exit-down notice.
6. Dev sideload, probe container, `-debugSandbox probe`.
*Done when:* all leak probes pass; exit swap without restart; main VPN off/on/TUN.

### M3 — pty display + permissions
1. `v2mac-pty`, socket bridge, resize/signals. 2. Permission approval + enforcement.
3. ssh-agent forwarding. 4. `hello-pty` (in `plugin-template`).
*Done when:* `hello-pty — Work` opens in Terminal and SSH with the agent works through the VM's exit.

### M4 — gui display
1. RFB parser + fuzz tests. 2. Stub, bundle generation, icon tint, title capsule.
3. Clipboard rules, Shared folder + quarantine, audio. 4. `hello-gui`.
*Done when:* `hello-gui — Work.app` is its own Mac app; input, resize, clipboard and Shared work.

### M5 — Store and templates
1. `store` repo: index format, Ledger signing script, expiry reminder workflow, submission CI, checklist.
2. Helper: index + manifest checks (SSHSIG, rollback, expiry, revocation, `api`, `from`).
3. Install/update (changed layers only)/remove, Verify Installation, revoked handling.
4. Add sheet: Empty / Template / Clone.
*Done when:* tampered layer/index and expired index are refused; a template makes a working mini VM.

### M6 — SDK
1. Base images released from `sandbox`. 2. `plugin-template` with CI, samples built from it.
3. Plugin API docs.
*Done when:* a new plugin from the template passes store CI and installs on a clean Mac.

### M7 — Hardening and release
1. Host leak script, sleep/wake/Wi-Fi/main-VPN scenarios, resource monitor.
2. Spec (app), wiki (en/fa/zh/ru), README ×4, String Catalogs ×3 (app and helper).
3. First locked release: sandbox tag, then V2Mac release pinning its hash.
*Done when:* every §9 scenario passes on a clean Mac; Sandbox (beta) ships.

## Verification
- `cd ../app/Packages/V2MacCore && swift test --filter Sandbox`; `swift test` in `sandbox`.
- Dev build only (`V2MacDev.app`, data in `v2mac-dev`); never touch the installed V2Mac or its core.
- `-debugSandbox install|boot|probe|launch <plugin>` hooks print `[v2mac-debug]` lines;
  `-debugSnapshot` checks the entry sheet; the helper gets its own snapshot hook.
