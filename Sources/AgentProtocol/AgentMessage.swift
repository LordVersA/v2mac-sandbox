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
    /// Helper → agent, first frame on a pty connection (port `ptyPort`): `sandbox.sh app` with these
    /// words on a new pty. `PtyInput` frames and raw terminal output follow.
    case pty([String])
    /// Helper → agent, first frame on a window connection (port `guiPort`): `sandbox.sh gui` with these
    /// words, then the client side of RFB (checked by `RFBClientFilter`) and wayvnc's answers.
    case gui([String])

    /// The only files `put` may write: the in-VM xray config, the gateway's nftables rules, and a
    /// plugin's launch command (`plugin-<vm>-<app>.argv`, NUL-separated) and environment (`.env`), per mini VM.
    public static let files: Set<String> = ["xray.json", "gateway.nft"]

    static func isFile(_ name: String) -> Bool {
        if files.contains(name) { return true }
        // exit-<mini VM id>.json: the exit facts sandbox.sh moves into that mini VM's /run/v2mac.
        if name.hasPrefix("exit-"), name.hasSuffix(".json"), case let id = String(name.dropFirst(5).dropLast(5)), isWord(id), !id.contains(".") { return true }
        guard name.hasPrefix("plugin-"), let dot = name.lastIndex(of: "."), [".argv", ".env"].contains(name[dot...]) else { return false }
        return isWord(String(name[name.index(name.startIndex, offsetBy: 7)..<dot])) && !name.dropFirst(7).hasPrefix(".")
    }

    public static let version = 1
    public static let port: UInt32 = 1024
    public static let ptyPort: UInt32 = 1026
    public static let guiPort: UInt32 = 1028
    /// The guest connects here for the Mac's ssh-agent, only while an approved pty app is open.
    public static let sshAgentPort: UInt32 = 1027
    public static let maxFrame = 64 * 1024

    public var frame: [UInt8] {
        let text: String = switch self {
        case .hello(let version): "hello \(version)"
        case .shutdown: "shutdown"
        case .ok: "ok"
        case .put(let name, let body): "put \(name) \(body)"
        case .run(let words): (["run"] + words).joined(separator: " ")
        case .pty(let words): (["pty"] + words).joined(separator: " ")
        case .gui(let words): (["gui"] + words).joined(separator: " ")
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
            guard Self.isFile(String(rest[1])) else { return nil }
            self = .put(name: String(rest[1]), body: String(rest[2]))
        case ("run", 2...), ("pty", 2...), ("gui", 2...):
            let args = words.dropFirst().map(String.init)
            guard args.allSatisfy(Self.isWord) else { return nil }
            self = switch words[0] { case "run": .run(args); case "pty": .pty(args); default: .gui(args) }
        case ("result", 2...):
            guard let status = Int(rest[1]) else { return nil }
            self = .result(status: status, output: rest.count > 2 ? String(rest[2]) : "")
        default: return nil
        }
    }

    /// Script arguments: verbs, indexes and ids only, so nothing reaches a shell as code.
    public static func isWord(_ word: String) -> Bool {
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

/// Terminal input on a pty connection, from `v2mac-pty` through the helper to the agent:
/// `[0][u16 length][bytes]` is keyboard input, `[1][u16 rows][u16 cols]` a resize.
public enum PtyInput: Equatable, Sendable {
    case data([UInt8])
    case resize(rows: Int, cols: Int)

    public var frame: [UInt8] {
        func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        return switch self {
        case .data(let bytes): [0] + be16(bytes.count) + bytes
        case .resize(let rows, let cols): [1] + be16(rows) + be16(cols)
        }
    }

    /// Collects bytes into whole frames; throws on an unknown frame type.
    public struct Reader: Sendable {
        private var buffer: [UInt8] = []
        public init() {}

        public mutating func feed(_ bytes: some Collection<UInt8>) throws(AgentMessage.Invalid) -> [PtyInput] {
            buffer += bytes
            var out: [PtyInput] = []
            var i = 0
            func u16(_ at: Int) -> Int { Int(buffer[at]) << 8 | Int(buffer[at + 1]) }
            while i + 3 <= buffer.count {
                switch buffer[i] {
                case 0:
                    let length = u16(i + 1)
                    guard i + 3 + length <= buffer.count else { break }
                    out.append(.data(Array(buffer[(i + 3)..<(i + 3 + length)])))
                    i += 3 + length
                    continue
                case 1:
                    guard i + 5 <= buffer.count else { break }
                    out.append(.resize(rows: u16(i + 1), cols: u16(i + 3)))
                    i += 5
                    continue
                default: throw AgentMessage.Invalid()
                }
                break
            }
            buffer.removeFirst(i)
            return out
        }
    }
}

/// The client half of an RFB 3.8 session as the agent passes it to wayvnc (plan §5 `gui`): the
/// handshake bytes, then only the standard client messages plus two of ours, which the agent handles
/// itself. Anything else, or clipboard text when the app may not have it, ends the session.
public struct RFBClientFilter: Sendable {
    public enum Out: Equatable, Sendable {
        /// Bytes for wayvnc.
        case forward([UInt8])
        /// Our 250: `[250][u32 length][UTF-8]`, text the agent types with wtype (Persian, IMEs).
        case text(String)
        /// Our 252: `[252][u16 width][u16 height][u8 scale]`, a new output mode from a window resize.
        case resize(width: Int, height: Int, scale: Int)
    }

    public static let maxText = 1 << 20
    /// ProtocolVersion (12), security type (1), ClientInit (1).
    static let handshake = 14
    private var buffer: [UInt8] = []
    private var handshakeLeft = RFBClientFilter.handshake
    private let clipboard: Bool

    public init(clipboard: Bool) { self.clipboard = clipboard }

    public mutating func feed(_ bytes: some Collection<UInt8>) throws(AgentMessage.Invalid) -> [Out] {
        buffer += bytes
        var out: [Out] = []
        if handshakeLeft > 0 {
            let n = min(handshakeLeft, buffer.count)
            out.append(.forward(Array(buffer[0..<n])))
            buffer.removeFirst(n)
            handshakeLeft -= n
            if handshakeLeft > 0 { return out }
        }
        while let length = try messageLength() {
            let message = Array(buffer[0..<length])
            buffer.removeFirst(length)
            switch message[0] {
            case 250: out.append(.text(String(decoding: message[5...], as: UTF8.self)))
            case 252: out.append(.resize(width: Int(message[1]) << 8 | Int(message[2]), height: Int(message[3]) << 8 | Int(message[4]), scale: Int(message[5])))
            case 6 where !clipboard: continue // no clipboard permission: Mac text never reaches the app
            default: out.append(.forward(message))
            }
        }
        return out
    }

    /// The whole first message's size, nil while it is incomplete.
    private func messageLength() throws(AgentMessage.Invalid) -> Int? {
        guard let type = buffer.first else { return nil }
        func u16(_ at: Int) -> Int { Int(buffer[at]) << 8 | Int(buffer[at + 1]) }
        func u32(_ at: Int) -> Int { u16(at) << 16 | u16(at + 2) }
        let length: Int
        switch type {
        case 0: length = 20 // SetPixelFormat
        case 2: guard buffer.count >= 4 else { return nil }; length = 4 + 4 * u16(2) // SetEncodings
        case 3: length = 10 // FramebufferUpdateRequest
        case 4: length = 8 // KeyEvent
        case 5: length = 6 // PointerEvent
        case 6, 250: // ClientCutText, our text
            let head = type == 6 ? 8 : 5
            guard buffer.count >= head else { return nil }
            guard u32(head - 4) <= Self.maxText else { throw AgentMessage.Invalid() }
            length = head + u32(head - 4)
        case 252: length = 6
        default: throw AgentMessage.Invalid()
        }
        return buffer.count >= length ? length : nil
    }
}
