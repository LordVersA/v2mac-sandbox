// Spike 0.12: the helper's check. Usage: verify <key.pub (OpenSSH ssh-ed25519)> <index.json> <index.json.sig>
import CryptoKit
import Foundation

let a = CommandLine.arguments
let pubB64 = try String(contentsOfFile: a[1], encoding: .utf8).split(separator: " ")[1]
let blob = Data(base64Encoded: String(pubB64))!
let raw = blob.suffix(32) // ssh-ed25519 wire blob ends with the 32-byte key
let key = try Curve25519.Signing.PublicKey(rawRepresentation: raw)
let index = try Data(contentsOf: URL(fileURLWithPath: a[2]))
let sig = Data(base64Encoded: try String(contentsOfFile: a[3], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
let ok = key.isValidSignature(sig, for: Data(SHA256.hash(data: index)))
print(ok ? "valid" : "INVALID")
exit(ok ? 0 : 1)
