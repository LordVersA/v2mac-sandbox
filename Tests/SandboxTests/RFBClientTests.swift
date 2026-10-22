import Foundation
import Testing
@testable import RFB

@Suite struct RFBClientTests {
    /// A client reading `server` and recording what it writes.
    final class Pipe: @unchecked Sendable {
        var input: [UInt8]
        var output: [UInt8] = []
        init(_ input: [UInt8]) { self.input = input }
        func client() -> RFBClient {
            RFBClient(read: { buf in
                let n = min(buf.count, self.input.count, 7) // short reads on purpose
                guard n > 0 else { return 0 }
                for i in 0..<n { buf[i] = self.input[i] }
                self.input.removeFirst(n)
                return n
            }, write: { self.output += $0 })
        }
    }

    static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    static func greeting(_ w: Int, _ h: Int) -> [UInt8] {
        Array("RFB 003.008\n".utf8) + [1, 1] + [0, 0, 0, 0] + be16(w) + be16(h) + [UInt8](repeating: 0, count: 16) + [0, 0, 0, 1] + [0x41]
    }
    static func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ enc: Int32) -> [UInt8] {
        be16(x) + be16(y) + be16(w) + be16(h) + withUnsafeBytes(of: enc.bigEndian) { Array($0) }
    }

    @Test func drawsRawAndCopyRectAndResizes() throws {
        let raw = Self.rect(1, 1, 1, 1, 0) + [9, 8, 7, 0]
        let copy = Self.rect(0, 0, 1, 1, 1) + Self.be16(1) + Self.be16(1)
        let size = Self.rect(0, 0, 3, 2, -223)
        let pipe = Pipe(Self.greeting(2, 2) + [0, 0] + Self.be16(2) + raw + copy + [3, 0, 0, 0, 0, 0, 0, 2, 0x68, 0x69] + [0, 0] + Self.be16(1) + size)
        let client = pipe.client()
        nonisolated(unsafe) var frames: [[UInt8]] = []
        nonisolated(unsafe) var cut = ""
        client.onFrame = { frames.append($0.framebuffer) }
        client.onCutText = { cut = $0 }
        try client.handshake()
        #expect(throws: RFBClient.Invalid.self) { try client.run() } // ends at "closed"
        #expect(frames.first.map { Array($0[0..<4]) } == [9, 8, 7, 0])
        #expect(frames.first.map { Array($0[12..<16]) } == [9, 8, 7, 0])
        #expect(cut == "hi")
        #expect(client.width == 3 && client.height == 2 && client.framebuffer.count == 24)
        #expect(pipe.output.starts(with: Array("RFB 003.008\n".utf8)))
    }

    @Test func refusesWhatAHostileGuestSends() throws {
        let bad: [[UInt8]] = [
            [0, 0] + Self.be16(1) + Self.rect(0, 0, 9000, 9000, -223),  // huge desktop
            [0, 0] + Self.be16(1) + Self.rect(0, 0, 1, 1, 16),          // ZRLE we never asked for
            [3, 0, 0, 0, 0x10, 0, 0, 0],                                 // 256 MB clipboard
            [9],                                                         // unknown message
        ]
        for stream in bad {
            let client = Pipe(Self.greeting(2, 2) + stream).client()
            try client.handshake()
            #expect(throws: RFBClient.Invalid.self) { try client.run() }
        }
        #expect(throws: RFBClient.Invalid.self) { try Pipe(Array("RFB 003.008\n".utf8) + [1, 2]).client().handshake() } // no None
        #expect(throws: RFBClient.Invalid.self) { try Pipe(Self.greeting(0, 5)).client().handshake() }
    }

    @Test func dropsStaleRectanglesAfterAResize() throws {
        let stale = Self.rect(1, 0, 2, 1, 0) + [1, 1, 1, 1, 2, 2, 2, 2]          // past the right edge
        let copy = Self.rect(0, 0, 1, 1, 1) + Self.be16(2) + Self.be16(0)        // CopyRect from outside
        let raw = Self.rect(0, 1, 1, 1, 0) + [9, 8, 7, 0]
        let client = Pipe(Self.greeting(2, 2) + [0, 0] + Self.be16(3) + stale + copy + raw).client()
        nonisolated(unsafe) var frames: [[UInt8]] = []
        client.onFrame = { frames.append($0.framebuffer) }
        try client.handshake()
        #expect(throws: RFBClient.Invalid.self) { try client.run() } // ends at "closed"
        #expect(frames == [[UInt8](repeating: 0, count: 8) + [9, 8, 7, 0] + [0, 0, 0, 0]])
    }

    @Test func survivesRandomStreams() {
        for _ in 0..<500 {
            let tail = (0..<Int.random(in: 0..<200)).map { _ in UInt8.random(in: 0...255) }
            let client = Pipe(Self.greeting(16, 16) + [0, 0] + Self.be16(1) + tail).client()
            try? client.handshake()
            try? client.run()
            #expect(client.framebuffer.count == client.width * client.height * 4)
        }
    }
}
