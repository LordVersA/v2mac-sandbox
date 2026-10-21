# CLAUDE.md (sandbox)

Everything of the Secure Sandbox that V2Mac downloads on demand: the helper app ("V2Mac Sandbox"),
the Swift VM agent and its protocol, the kernel config, the Debian rootfs and the base images.
Plan and every decision: `docs/PLAN.md` (read the section before changing what it describes).

- V2Mac.app holds no sandbox code beyond the entry sheet, the download and the link (`PLAN.md` §1–2).
  Anything else belongs here.
- SwiftPM; `V2MacCore` comes by path from `../app/Packages/V2MacCore`. CI checks the app out at the
  pinned tag beside this repo. Link message types live in the app package; change both together.
- Releases are locked to V2Mac releases: a V2Mac release pins one sandbox release by SHA-256. Tag the
  sandbox first, then the app pins it.
- The VM has no network device and never sees server configs or keys.
- Kernel: own minimal config from the kernel.org LTS; rootfs: Debian 13 arm64 via `mmdebstrap`
  with `SOURCE_DATE_EPOCH`, packages only from Debian's signed archive.
- Testing follows `../app/CLAUDE.md`: dev build only, never touch the installed V2Mac or its core.
- Not on GitHub yet: no remote, no pushing until the user asks.
