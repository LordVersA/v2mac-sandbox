<p align="center"><img src="https://raw.githubusercontent.com/LordVersA/v2mac/main/docs/images/banner.jpg" alt="V2Mac" width="720"></p>

<h1 align="center">V2Mac Secure Sandbox</h1>

<p align="center"><b>Run apps in mini VMs, each with its own server, on your Mac.</b><br>
Every app opens as its own Mac app, and nothing it does reaches the internet except through the server you pick. Fail-closed, always.</p>

<p align="center">
  <a href="https://github.com/LordVersA/v2mac-sandbox/releases/latest"><img src="https://img.shields.io/github/v/release/LordVersA/v2mac-sandbox?label=release&color=0A84FF" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/status-beta-FF9F0A" alt="Beta">
  <img src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple" alt="macOS 26 or later">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-555555" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/Debian-13-A81D33?logo=debian&logoColor=white" alt="Debian 13">
</p>

<p align="center">
  <a href="#get-it">Get it</a> ·
  <a href="#features">Features</a> ·
  <a href="#how-it-works">How it works</a> ·
  <a href="https://github.com/LordVersA/v2mac/wiki/Sandbox"><b>Documentation</b></a> ·
  <a href="#build-from-source">Build</a>
</p>

Open a browser in a mini VM that leaves from Frankfurt, a terminal in another that leaves from Tokyo, and keep your Mac on your normal connection. Each mini VM is cut off from your Mac's files, your network and every other mini VM. If its server stops working, its apps go offline; they never fall back to your normal connection.

The sandbox is part of [**V2Mac**](https://github.com/LordVersA/v2mac). This repo holds everything V2Mac downloads the first time you open it: the helper app, the VM agent, the kernel and the Debian image. Users who never open the sandbox download nothing.

## Get it

Install [V2Mac](https://github.com/LordVersA/v2mac#install), then click **Sandbox** in the sidebar or the menu bar panel and choose **Download**. V2Mac accepts only the exact sandbox release it was built with (checked by SHA-256), and offers an update when a new V2Mac needs a newer one. Your mini VMs and their data stay.

## Features

- **Mini VMs:** add as many as you like: empty, from a template, or cloned with their apps and data. Each has a colour, a name and an exit.
- **One exit per mini VM:** any server from V2Mac (VLESS, REALITY, VMess, Trojan, Shadowsocks, Hysteria2, WireGuard…), changeable live, or no internet at all. A red **Not connected** and one notification when it stops; V2Mac never switches on its own.
- **Real Mac apps:** every app in every mini VM becomes its own app in `~/Applications/V2Mac Sandbox` ("Chromium — Work"), with its own window, Dock icon and ⌘-Tab entry, its icon framed in the mini VM's colour. Terminal apps open in Terminal.
- **Signed store:** install apps such as [Chromium](https://github.com/LordVersA/v2mac-chromium) from the [V2Mac store](https://github.com/LordVersA/v2mac-store). Every app is pinned to its source commit and hashes, reviewed, and checkable with **Verify Installation…**
- **Linux Packages (beta):** search Debian's archive and install any package; its apps appear like store apps.
- **Permissions you control:** clipboard per direction, a Shared folder per mini VM, and sound, microphone and SSH keys asked at first use (**Allow**, **Don't Allow**, **Always Allow**).
- **Nothing leaks by design:** the VM has no network device and never sees a server config or key. Apps match their exit's time zone. Files they save to your Mac are quarantined so macOS checks them.
- **Disposable mini VMs:** data erased whenever the sandbox stops. Or wipe one any time.
- **Light on your Mac:** one hidden VM for every mini VM, started when you open an app and stopped 5 minutes after the last one closes, with a memory limit you set.
- English, Persian, Chinese and Russian.

## How it works

```
V2Mac ── socketpair ──▶ V2Mac Sandbox (helper)
                          │  xray: one outbound per mini VM
                          │  windows (VNC), Terminal (pty), sound, clipboard
                          ▼  vsock only
                        Linux VM (Virtualization.framework, no network device)
                          agent ─▶ one Podman pod per mini VM ─▶ apps
```

- **V2Mac** checks the helper's hash, launches it and hands it one end of a socketpair; there is no listening socket for anything else to ask.
- **The helper** runs its own Xray core with one ready outbound per mini VM, the Sandbox window, the store, and the bridges for each app's window, terminal, sound and clipboard.
- **The VM** boots our own minimal kernel (kernel.org LTS) and a read-only Debian 13 root built with `mmdebstrap` from Debian's signed archive. A Swift agent owns vsock and runs each mini VM as its own Podman pod; its only way out is a relay to its own outbound in the helper.
- **Plugins** are OCI layers on the sandbox's own root, so an app downloads only what it adds.

Design and every decision: [docs/PLAN.md](docs/PLAN.md).

## Documentation

| | |
|---|---|
| [Secure Sandbox guide](https://github.com/LordVersA/v2mac/wiki/Sandbox) | Getting it, mini VMs, apps, permissions, settings |
| [Plugin template](https://github.com/LordVersA/v2mac-plugin-template) | Make your own sandbox app |
| [Store](https://github.com/LordVersA/v2mac-store) | The signed index, submissions and review checklist |

## Build from source

Needs Xcode 26+, Docker (arm64) and this repo beside the app, as `../app` (it uses `V2MacCore` by path):

```sh
Scripts/build-agent.sh && Scripts/build-kernel.sh && Scripts/build-rootfs.sh   # Linux side, in Docker
Scripts/build-helper.sh                                                         # out/V2Mac Sandbox.app
Scripts/package.sh <download-url>                                               # zip + pin.json
```

Tests: `swift test`. A tag `vX.Y.Z` builds and publishes a release ([release.yml](.github/workflows/release.yml)); the V2Mac release that follows pins its `pin.json`. Bug reports go to [V2Mac's Issues](https://github.com/LordVersA/v2mac/issues).
