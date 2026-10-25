#!/bin/sh
# Publishes out/V2Mac Sandbox.app file by file (docs/delta-updates.md): out/release/ gets one zip per
# file, the bsdiff patches from out/patches/ (release CI's patch job) and files.json, the manifest;
# out/pin.json is the `SandboxPin` a V2Mac release (or a dev build's -debugSandboxPin) accepts.
# Usage: package.sh <URL of files.json>; the manifest names its files relative to it.
set -e
cd "$(dirname "$0")/.."
[ -n "$1" ] || { echo "usage: $0 <url>"; exit 2; }
APP="out/V2Mac Sandbox.app"
# The manifest carries regular files only: an empty folder or a link would be lost on install.
[ -z "$(find "$APP" ! -type f ! -type d)$(find "$APP" -type d -empty)" ] || { echo "$APP has links or empty folders"; exit 1; }
rm -rf out/release && mkdir -p out/release
python3 - "$APP" "$1" <<'PY'
import hashlib, json, os, subprocess, sys
app, url = sys.argv[1], sys.argv[2]
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
def source(path, name):
    return {"url": name, "sha256": sha(path), "size": os.path.getsize(path)}
patches = os.listdir("out/patches") if os.path.isdir("out/patches") else []
files = []
for d, _, names in sorted(os.walk(app)):
    for n in sorted(names):
        full = os.path.join(d, n)
        rel = os.path.relpath(full, app)
        asset = rel.removeprefix("Contents/").replace("/", "_").replace(" ", "_")
        subprocess.run(["ditto", "-c", "-k", full, f"out/release/{asset}.zip"], check=True)
        entry = {"path": rel, "sha256": sha(full), "size": os.path.getsize(full),
                 "executable": os.access(full, os.X_OK), "zip": source(f"out/release/{asset}.zip", f"{asset}.zip"), "patches": []}
        for p in sorted(patches):
            if not (p.startswith(asset + ".from-") and p.endswith(".bsdiff")):
                continue
            src = f"out/patches/{p}"
            # A patch near the zip's size saves little and costs a bspatch (plan: D2).
            if os.path.getsize(src) > 0.6 * entry["zip"]["size"]:
                print("skipped", p)
                continue
            os.link(src, f"out/release/{p}")
            entry["patches"].append({"from": open(src + ".from").read().strip(), **source(src, p)})
        files.append(entry)
version = subprocess.run(["plutil", "-extract", "CFBundleShortVersionString", "raw", f"{app}/Contents/Info.plist"],
                         capture_output=True, text=True, check=True).stdout.strip()
json.dump({"version": version, "files": files}, open("out/release/files.json", "w"), indent=1)
helper = next(f for f in files if f["path"] == "Contents/MacOS/V2Mac Sandbox")
pin = {"url": url, "sha256": sha("out/release/files.json"), "executableSHA256": helper["sha256"],
       "size": sum(f["zip"]["size"] for f in files), "version": version}
json.dump(pin, open("out/pin.json", "w"))
print(json.dumps(pin))
PY
