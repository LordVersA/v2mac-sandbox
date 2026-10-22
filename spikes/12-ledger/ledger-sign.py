"""Spike 0.12: sign a file with the Ledger SSH/PGP Agent app (Ed25519) as an OpenSSH SSHSIG.

Usage: ledger-sign.py pubkey > key.pub
       ledger-sign.py hash <file>   -> <file>.sig = base64 Ed25519 signature over SHA-256(file)
       (The app's SSH command only signs SSH login requests, so OpenSSH SSHSIG files aren't possible;
       INS 06 hashes the data with SHA-256 on the device and signs that hash.)
APDUs from trezor-agent's last Ledger driver (romanz/trezor-agent@b782b610a9, libagent/device/ledger.py).
"""
import base64, hashlib, struct, sys
from ledgerblue import comm

# SLIP-13-style hardened path for the store key (fixed, so the key is reproducible from the seed).
PATH = [13 | 0x80000000, 0x76326d61 | 0x80000000, 1 | 0x80000000, 0x80000000, 0x80000000]
NAMESPACE = b"v2mac-store"

def path_bytes():
    return bytes([len(PATH)]) + b"".join(struct.pack(">I", e) for e in PATH)

def ssh_string(b):
    return struct.pack(">I", len(b)) + b

def pubkey(dongle):
    p = path_bytes()
    r = bytearray(dongle.exchange(bytes([0x80, 0x02, 0x00, 0x02, len(p)]) + p))[1:]
    # reply: 0x04 || X (32, big endian) || Y (32, big endian) -> Ed25519 = Y little endian with X's sign bit
    x, y = r[1:33], bytearray(r[33:65][::-1])
    if x[31] & 1:
        y[31] |= 0x80
    return bytes(y)

def sign(dongle, blob, ins, p2):
    p = path_bytes()
    off, res = 0, None
    while off < len(blob) or off == 0:
        data = p if off == 0 else b""
        n = min(len(blob) - off, 255 - len(data))
        data += blob[off:off + n]
        last = off + n == len(blob)
        p1 = (0x80 if last else 0x00) | (0x00 if off == 0 else 0x01)
        res = dongle.exchange(bytes([0x80, ins, p1, p2, len(data)]) + data)
        off += n
        if last:
            break
    return bytes(res[:64])

def openssh_pub(pk):
    return b"ssh-ed25519 " + base64.b64encode(ssh_string(b"ssh-ed25519") + ssh_string(pk)) + b" v2mac-store-spike"

def main():
    dongle = comm.getDongle()
    pk = pubkey(dongle)
    if sys.argv[1] == "pubkey":
        print(openssh_pub(pk).decode()); return
    path = sys.argv[2]
    if sys.argv[1] == "hash":
        sig = sign(dongle, open(path, "rb").read(), 0x06, 0x02)
        open(path + ".sig", "w").write(base64.b64encode(sig).decode() + "\n")
        print("wrote", path + ".sig"); return
    mode = sys.argv[3] if len(sys.argv) > 3 else "raw"
    msg_hash = hashlib.sha512(open(path, "rb").read()).digest()
    # What OpenSSH signs for SSHSIG (PROTOCOL.sshsig): magic, namespace, reserved, hash alg, H(message).
    signed = b"SSHSIG" + ssh_string(NAMESPACE) + ssh_string(b"") + ssh_string(b"sha512") + ssh_string(msg_hash)
    sig = sign(dongle, signed, 0x04, 0x82) if mode == "ssh" else sign(dongle, signed, 0x08, 0x02)
    pubblob = ssh_string(b"ssh-ed25519") + ssh_string(pk)
    body = (b"SSHSIG" + struct.pack(">I", 1) + ssh_string(pubblob) + ssh_string(NAMESPACE) + ssh_string(b"")
            + ssh_string(b"sha512") + ssh_string(ssh_string(b"ssh-ed25519") + ssh_string(sig)))
    b64 = base64.b64encode(body).decode()
    with open(path + ".sig", "w") as f:
        f.write("-----BEGIN SSH SIGNATURE-----\n" + "\n".join(b64[i:i + 70] for i in range(0, len(b64), 70)) + "\n-----END SSH SIGNATURE-----\n")
    print("wrote", path + ".sig")

main()
