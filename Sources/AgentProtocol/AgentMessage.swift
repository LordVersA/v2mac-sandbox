/// Messages between the helper and the VM agent on vsock port 1024 (plan §3). The agent accepts only
/// this fixed set. A frame is a 4-byte big-endian length and that many bytes of UTF-8 text: the
/// message name, then its arguments separated by single spaces.
public enum AgentMessage: Equatable, Sendable {
    /// Agent → helper, first frame on every connection.
    case hello(version: Int)
    /// Helper → agent: power the VM off cleanly (flushes the data disk).
    case shutdown
    /// Agent → helper: the request was done.
    case ok
    /// Helper → agent: write `body` to `/run/v2mac/<name>`; `name` is one of `files`.
    case put(name: String, body: String)
    /// Helper → agent: run the gateway script (`/usr/local/lib/v2mac/sandbox.sh`) with these words.
    case run([String])
    /// Agent → helper: the script's exit status and output.
    case result(status: Int, output: String)

    /// The only files `put` may write: the in-VM xray config and the gateway's nftables rules.
    public static let files: Set<String> = ["xray.json", "gateway.nft"]

    public static let version = 1
    public static let port: UInt32 = 1024
    public static let maxFrame = 64 * 1024

    public var frame: [UInt8] {
        let text: String = switch self {
        case .hello(let version): "hello \(version)"
        case .shutdown: "shutdown"
        case .ok: "ok"
        case .put(let name, let body): "put \(name) \(body)"
        case .run(let words): (["run"] + words).joined(separator: " ")
        case .result(let status, let output): "result \(status) \(output)"
        }
        let body = Array(text.utf8)
        let n = UInt32(body.count)
        return [UInt8(n >> 24), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)] + body
    }

    init?(text: String) {
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        // put and result end in free text: everything after the second space.
        let rest = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        switch (words.first, words.count) {
        case ("hello", 2): guard let v = Int(words[1]) else { return nil }; self = .hello(version: v)
        case ("shutdown", 1): self = .shutdown
        case ("ok", 1): self = .ok
        case ("put", 3...):
            guard Self.files.contains(String(rest[1])) else { return nil }
            self = .put(name: String(rest[1]), body: String(rest[2]))
        case ("run", 2...):
            let args = words.dropFirst().map(String.init)
            guard args.allSatisfy(Self.isWord) else { return nil }
            self = .run(args)
        case ("result", 2...):
            guard let status = Int(rest[1]) else { return nil }
            self = .result(status: status, output: rest.count > 2 ? String(rest[2]) : "")
        default: return nil
        }
    }

    /// Script arguments: verbs, indexes and ids only, so nothing reaches a shell as code.
    static func isWord(_ word: String) -> Bool {
        !word.isEmpty && word.utf8.count <= 64 && word.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5a) || ($0 >= 0x61 && $0 <= 0x7a) || $0 == 0x2d || $0 == 0x2e
        }
    }

    public struct Invalid: Error {}

    /// Collects bytes and hands out whole messages; throws on an oversized or unknown frame, after
    /// which the connection must be closed.
    public struct Reader: Sendable {
        private var buffer: [UInt8] = []
        public init() {}

        public mutating func feed(_ bytes: some Collection<UInt8>) throws(Invalid) -> [AgentMessage] {
            buffer += bytes
            var messages: [AgentMessage] = []
            while buffer.count >= 4 {
                let length = buffer[0..<4].reduce(0) { $0 << 8 | Int($1) }
                guard length <= AgentMessage.maxFrame else { throw Invalid() }
                guard buffer.count >= 4 + length else { break }
                guard let message = AgentMessage(text: String(decoding: buffer[4..<(4 + length)], as: UTF8.self)) else { throw Invalid() }
                messages.append(message)
                buffer.removeFirst(4 + length)
            }
            return messages
        }
    }
}
