# io_uring is denied too: IORING_OP_SOCKET would create a socket without socket(). The kernel
# is also built without io_uring; this keeps the profile safe on its own.
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
for r in p["syscalls"]:
    r["names"] = [n for n in r["names"] if not n.startswith("io_uring")]
p["syscalls"] = [r for r in p["syscalls"] if r["names"]]
p["syscalls"].append({"names": ["io_uring_setup", "io_uring_enter", "io_uring_register"], "action": "SCMP_ACT_ERRNO", "errnoRet": 1})
json.dump(p, open(sys.argv[2], "w"))
