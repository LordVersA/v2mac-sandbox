# Podman's default seccomp profile with socket() narrowed to a family allowlist that leaves out
# AF_VSOCK (40). Netlink (16) stays allowed except NETLINK_AUDIT (9), as in the default profile.
import json, sys
p = json.load(open(sys.argv[1]))
p["syscalls"] = [r for r in p["syscalls"] if r["names"] != ["socket"]]
for r in p["syscalls"]:
    if "socket" in r["names"]:
        r["names"].remove("socket")
def allow(*args): return {"names": ["socket"], "action": "SCMP_ACT_ALLOW", "args": list(args)}
eq = lambda i, v: {"index": i, "value": v, "op": "SCMP_CMP_EQ"}
p["syscalls"] += [allow(eq(0, f)) for f in range(46) if f not in (16, 40)]
p["syscalls"].append(allow(eq(0, 16), {"index": 2, "value": 9, "op": "SCMP_CMP_NE"}))
p["syscalls"].append({"names": ["socket"], "action": "SCMP_ACT_ERRNO", "errnoRet": 1, "args": [eq(0, 40)]})
json.dump(p, open(sys.argv[2], "w"))
