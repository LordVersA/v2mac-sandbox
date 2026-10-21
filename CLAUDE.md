# CLAUDE.md (sandbox-runtime)

Builds the Secure Sandbox's Linux VM and the base images plugins start from. Plan:
`../app/docs/SANDBOX.md` §2 and §6; work starts in milestone M1 (M0 spikes may live here too).

- Output per release: `vmlinuz`, `initrd`, `rootfs.erofs`, their `.sha256` and an Ed25519 signature,
  plus the OCI base images `base`, `base-cli` and `base-gui`.
- Debian 13 arm64 via `mmdebstrap` with `SOURCE_DATE_EPOCH`; packages only from Debian's signed archive.
- The image has no network device and no secrets. Server configs never enter it.
- The app's package parses and checks what this repo publishes: change formats on both sides together.
- Not on GitHub yet: no remote, no pushing until the user asks.
