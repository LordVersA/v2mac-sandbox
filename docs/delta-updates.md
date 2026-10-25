# Delta updates (workspace Phase 11)

**Goal:** a sandbox update downloads only what changed: unchanged files not at all, the rootfs as a
binary patch from the installed version when that is small enough, anything else in full.

## Today
- Each sandbox release is one `V2MacSandbox.zip` (362 MB) holding `V2Mac Sandbox.app`. The bundle has 12
  files; four carry the weight: `rootfs.erofs` 483 MB, kernel `Image` 10 MB, helper 5 MB, icon 1.7 MB.
- A V2Mac release pins that zip by SHA-256 (`SandboxPin`: zip hash, size, helper hash). On update the app
  downloads the whole zip again (`ResumableDownload`), checks it, unpacks it with `ditto` into `staging/`
  and swaps the bundle (`SandboxFiles.install`).
- The rootfs holds the agent and `sandbox.sh`, so it changes in nearly every release.

## Decisions
| Topic | Decision |
|---|---|
| Unit | The file inside the bundle. Unchanged files are copied from the installed bundle (an APFS clone), never downloaded. |
| Patches | Only for big files (rootfs; kernel if the spike shows it pays). bsdiff format, applied with macOS's own `/usr/bin/bspatch`: no new dependency in the app. |
| Old versions | **No chain of patches.** CI makes one direct patch from each of the last 3 releases to the new one. An older install downloads the changed files in full. A chain adds up to more bytes than a full download, multiplies failure points, and makes CI keep every release. |
| Patch key | A patch is chosen by the SHA-256 of the installed file (`from`), not by version, so a damaged or modified file falls back to the full download. |
| Trust | Unchanged: the V2Mac release pins one hash, now of the release's manifest instead of the zip. Every file and patch is checked against the manifest **before** use (so bspatch only ever sees pinned bytes), every patch result against its target hash, and the helper hash before every launch as today. No new key. |
| Full files | Each file is published zipped on its own (`ditto -c -k`), so the app keeps unpacking with `ditto` as it does now. |
| Fallback | Any failure in a patch (download, hash, bspatch) downloads that file in full; a failure there aborts and keeps the installed sandbox, as today. |
| App DMG | Out of scope. 28 MB, and Homebrew always downloads the full DMG anyway. Revisit only if users ask. |

## Release files (per sandbox tag)
- `files.json`, the manifest, pinned by V2Mac:
  ```json
  {"version": "1.1.0",
   "files": [{"path": "Contents/Resources/rootfs.erofs", "sha256": "…", "size": 483430400, "executable": false,
              "zip": {"url": "…/rootfs.erofs.zip", "sha256": "…", "size": 0},
              "patches": [{"from": "<sha256 of the old file>", "url": "…/rootfs.erofs.from-1.0.0.bsdiff",
                           "sha256": "…", "size": 0}]}]}
  ```
  Paths are relative, inside the bundle, without `..`; only regular files (the app refuses anything else).
- One `<file>.zip` per bundle file, and `<file>.from-<old version>.bsdiff` for each patch.
- `V2MacSandbox.zip` and `pin.json` stop being published once the first V2Mac that reads manifests is
  out. Older V2Mac releases keep pointing to their own old release, whose zip stays on GitHub.

## Install, in the app (`SandboxFiles`, package)
1. Download the manifest, check its hash against the pin, validate the paths.
2. Plan each file: installed copy has the target hash → **copy**; it matches a patch's `from` → **patch**;
   otherwise → **full**. The update sheet shows the sum of what will be downloaded.
3. Fill `staging/` file by file (resumable partials per file), check every hash.
4. Check the helper hash, swap the bundle as today, delete partials.

The planning step is a pure function and gets package tests; bspatch gets an integration test on small
files.

## Tasks
| # | Task | Repo |
|---|---|---|
| D0 | **Spike.** (a) Two builds of the same commit give byte-identical files (rootfs, `Image`, helper): fix what isn't (erofs UUID `-U`, kernel build stamps, signing). (b) bsdiff patch size, rootfs v1.0.0 → current main, also against an uncompressed erofs. (c) `/usr/bin/bspatch` peak memory and time on 483 MB (`/usr/bin/time -l`), and that Debian's `bsdiff` output is accepted by it. (d) bsdiff time and memory on the CI runner. **Go** if a patch is under 30 % of the zipped file and bspatch stays under 1.5 GB; otherwise ship D1–D3 without patches. | sandbox |
| D1 | `Scripts/package.sh` writes the per-file zips and `files.json`; release CI publishes them. | sandbox |
| D2 | Patch job in release CI: download the last 3 releases' rootfs, bsdiff each against the new one, add them to the manifest; skip a patch bigger than 60 % of the zip. | sandbox |
| D3 | App: `SandboxPin` points to the manifest; planning, per-file download, copy/patch/full, update sheet size. Package tests. Spec 12.11 and the wiki Sandbox page ×4; String Catalogs ×3 for any new text. | app, wiki |
| D4 | Check end to end with the dev build: v1.0.0 installed → new release served locally (`python3 -m http.server`, `-debugSandboxPin`): only the patch and changed files are fetched; break the patch's hash and see the full download take over; break the zip and see the old sandbox kept. | app, sandbox |

**Done when:** a dev build updating from each of the last 3 releases downloads only the patch and the
changed files, an older install falls back to full files, and all hash failures keep the installed
sandbox.
