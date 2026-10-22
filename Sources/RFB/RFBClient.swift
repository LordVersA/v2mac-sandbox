import Foundation

/// RFB 3.8 client for a sandbox window (plan §5 `gui`): Raw, CopyRect and DesktopSize, 32-bit BGRX.
/// The guest is hostile: every rectangle and CopyRect source is checked against the framebuffer and
/// sizes are capped before anything is written. Runs on one thread, reading through `read`.
public final class RFBClient: @unchecked Sendable {
    public struct Invalid: Error, Equatable {
        public var reason: String
        init(_ reason: String) { self.reason = reason }
    }

    public static let maxSide = 8192
    public static let maxCutText = 1 << 20

    public private(set) var width = 0
    public private(set) var height = 0
    /// BGRX, `width * height * 4` bytes; touch only from `onFrame`.
    public private(set) var framebuffer: [UInt8] = []

    /// Called after each whole update (and after a resize).
    public var onFrame: @Sendable (RFBClient) -> Void = { _ in }
    /// The app's copied text (ServerCutText).
    public var onCutText: @Sendable (String) -> Void = { _ in }

    private let read: @Sendable (UnsafeMutableRawBufferPointer) -> Int
    private let write: @Sendable ([UInt8]) -> Void

    /// `read` fills as much of the buffer as it can and returns the count, 0 or less at the end.
    public init(read: @escaping @Sendable (UnsafeMutableRawBufferPointer) -> Int, write: @escaping @Sendable ([UInt8]) -> Void) {
        self.read = read
        self.write = write
    }

    private func readExactly(into buffer: UnsafeMutableRawBufferPointer) throws {
        var got = 0
        while got < buffer.count {
            let n = read(UnsafeMutableRawBufferPointer(rebasing: buffer[got...]))
            guard n > 0 else { throw Invalid("closed") }
            got += n
        }
    }

    private func bytes(_ n: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: n)
        try out.withUnsafeMutableBytes { (b) throws in try readExactly(into: b) }
        return out
    }

    private func skip(_ n: Int) throws {
        var left = n
        while left > 0 { left -= try bytes(min(left, 65536)).count }
    }

    static func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
    static func u32(_ b: [UInt8], _ i: Int) -> Int { u16(b, i) << 16 | u16(b, i + 2) }
    static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    static func be32(_ v: Int) -> [UInt8] { be16(v >> 16) + be16(v & 0xffff) }

    /// Version, None security, shared ClientInit, then our pixel format and encodings.
    public func handshake() throws {
        let version = try bytes(12)
        guard version.starts(with: Array("RFB 003.".utf8)) else { throw Invalid("not RFB") }
        write(Array("RFB 003.008\n".utf8))
        let count = try bytes(1)[0]
        guard count > 0, try bytes(Int(count)).contains(1) else { throw Invalid("no None security") }
        write([1])
        guard try bytes(4) == [0, 0, 0, 0] else { throw Invalid("security failed") }
        write([1])
        let info = try bytes(24)
        try resize(Self.u16(info, 0), Self.u16(info, 2))
        let nameLength = Self.u32(info, 20)
        guard nameLength <= 4096 else { throw Invalid("name too long") }
        try skip(nameLength)
        // 32 bpp, depth 24, little endian, true colour, max 255 each, shifts r16 g8 b0 = BGRX in memory
        write([0, 0, 0, 0, 32, 24, 0, 1] + Self.be16(255) + Self.be16(255) + Self.be16(255) + [16, 8, 0, 0, 0, 0])
        let encodings = [1, 0, -223] // CopyRect, Raw, DesktopSize
        write([2, 0] + Self.be16(encodings.count) + encodings.flatMap { Self.be32(Int(UInt32(bitPattern: Int32($0)))) })
        requestUpdate(incremental: false)
    }

    public func requestUpdate(incremental: Bool) {
        write([3, incremental ? 1 : 0] + Self.be16(0) + Self.be16(0) + Self.be16(width) + Self.be16(height))
    }

    private func resize(_ w: Int, _ h: Int) throws {
        guard (1...Self.maxSide).contains(w), (1...Self.maxSide).contains(h) else { throw Invalid("bad framebuffer size") }
        width = w
        height = h
        framebuffer = [UInt8](repeating: 0, count: w * h * 4)
    }

    /// Reads server messages until the connection ends or the guest sends something invalid.
    public func run() throws {
        while true {
            switch try bytes(1)[0] {
            case 0: try update()
            case 2: break // Bell
            case 3:
                let head = try bytes(7)
                let length = Self.u32(head, 3)
                guard length <= Self.maxCutText else { throw Invalid("clipboard text too long") }
                let text = try bytes(length)
                onCutText(String(bytes: text, encoding: .utf8) ?? String(decoding: text.map { UInt16($0) }, as: UTF16.self))
            default: throw Invalid("unexpected message")
            }
        }
    }

    private func update() throws {
        let head = try bytes(3)
        for _ in 0..<Self.u16(head, 1) {
            let r = try bytes(12)
            let x = Self.u16(r, 0), y = Self.u16(r, 2), w = Self.u16(r, 4), h = Self.u16(r, 6)
            let encoding = Int32(bitPattern: UInt32(Self.u32(r, 8)))
            if encoding == -223 { try resize(w, h); continue }
            guard x + w <= width, y + h <= height else { throw Invalid("rectangle outside the framebuffer") }
            switch encoding {
            case 0:
                try framebuffer.withUnsafeMutableBytes { (fb) throws in
                    for row in 0..<h {
                        let start = ((y + row) * width + x) * 4
                        try readExactly(into: UnsafeMutableRawBufferPointer(rebasing: fb[start..<(start + w * 4)]))
                    }
                }
            case 1:
                let source = try bytes(4)
                let sx = Self.u16(source, 0), sy = Self.u16(source, 2)
                guard sx + w <= width, sy + h <= height else { throw Invalid("bad CopyRect source") }
                let rows = sy < y ? Array((0..<h).reversed()) : Array(0..<h)
                let width = width
                framebuffer.withUnsafeMutableBytes { fb in
                    for row in rows {
                        memmove(fb.baseAddress! + ((y + row) * width + x) * 4, fb.baseAddress! + ((sy + row) * width + sx) * 4, w * 4)
                    }
                }
            default: throw Invalid("unexpected encoding")
            }
        }
        onFrame(self)
        requestUpdate(incremental: true)
    }

    // MARK: Input

    public func key(_ sym: UInt32, down: Bool) { write([4, down ? 1 : 0, 0, 0] + Self.be32(Int(sym))) }

    /// Presses `sym` with `mods` held, then releases everything.
    public func tap(_ sym: UInt32, mods: [UInt32] = []) {
        mods.forEach { key($0, down: true) }
        key(sym, down: true)
        key(sym, down: false)
        mods.reversed().forEach { key($0, down: false) }
    }

    public func pointer(buttons: UInt8, x: Int, y: Int) {
        write([5, buttons] + Self.be16(min(max(0, x), max(0, width - 1))) + Self.be16(min(max(0, y), max(0, height - 1))))
    }

    /// Mac clipboard text for the app (ClientCutText); sent only on ⌘V.
    public func cutText(_ text: String) {
        let bytes = Array(text.utf8.prefix(Self.maxCutText))
        write([6, 0, 0, 0] + Self.be32(bytes.count) + bytes)
    }

    /// Our 250: text RFB keysyms can't carry (Persian, IMEs); the agent types it.
    public func text(_ text: String) {
        let bytes = Array(text.utf8.prefix(Self.maxCutText))
        write([250] + Self.be32(bytes.count) + bytes)
    }

    /// Our 252: a new output size in pixels.
    public func requestSize(width: Int, height: Int, scale: Int) {
        write([252] + Self.be16(width) + Self.be16(height) + [UInt8(scale)])
    }
}
