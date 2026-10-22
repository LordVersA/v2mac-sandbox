import Testing
@testable import AgentProtocol

@Suite struct AgentProtocolTests {
    @Test func messagesRoundTripAcrossSplitFrames() throws {
        let sent: [AgentMessage] = [
            .hello(version: 1), .shutdown, .ok, .put(name: "xray.json", body: "{\"a\": [1, 2]}\n"),
            .run(["vm-add", "3", "a1b2", "0"]), .pty(["app", "3", "a1b2", "hello-pty", "0", "1"]),
            .put(name: "plugin-hello-pty.argv", body: "bash\0-l\0"), .put(name: "plugin-hello-pty.env", body: "A=b\n"), .result(status: 1, output: "FAIL x\nPASS y"), .result(status: 0, output: ""),
        ]
        let bytes = sent.flatMap(\.frame)
        var reader = AgentMessage.Reader()
        var got: [AgentMessage] = []
        for start in stride(from: 0, to: bytes.count, by: 3) {
            got += try reader.feed(bytes[start..<min(start + 3, bytes.count)])
        }
        #expect(got == sent)
    }

    @Test func refusesUnknownAndOversizedFrames() {
        for text in ["reboot", "hello", "hello x", "shutdown now", "", "put /etc/passwd x", "put xray.json",
                     "run", "run a;reboot", "run $(x)", "run a  b", "result x y",
                     "pty", "pty a;b", "put plugin-.argv x", "put plugin-a/b.env x", "put plugin-..argv x", "put plugin-a.sh x"] {
            var reader = AgentMessage.Reader()
            let body = Array(text.utf8)
            #expect(throws: AgentMessage.Invalid.self) { try reader.feed([0, 0, 0, UInt8(body.count)] + body) }
        }
        var reader = AgentMessage.Reader()
        #expect(throws: AgentMessage.Invalid.self) { try reader.feed([0, 1, 0, 1]) }
    }

    @Test func ptyInputRoundTripsAndRefusesUnknownTypes() throws {
        let sent: [PtyInput] = [.resize(rows: 40, cols: 120), .data(Array("ls\r".utf8)), .data([3]), .data([])]
        let bytes = sent.flatMap(\.frame)
        var reader = PtyInput.Reader()
        var got: [PtyInput] = []
        for b in bytes { got += try reader.feed([b]) }
        #expect(got == sent)
        #expect(throws: AgentMessage.Invalid.self) { try reader.feed([2, 0, 0]) }
    }

    @Test func rfbFilterPassesStandardMessagesAndTakesOurs() throws {
        let handshake = Array("RFB 003.008\n".utf8) + [1, 1]
        let key: [UInt8] = [4, 1, 0, 0, 0, 0, 0, 0x61]
        let cut: [UInt8] = [6, 0, 0, 0, 0, 0, 0, 2] + Array("hi".utf8)
        let text: [UInt8] = [250, 0, 0, 0, 6] + Array("سلام".utf8.prefix(6))
        let resize: [UInt8] = [252, 5, 0, 3, 32, 2]
        let encodings: [UInt8] = [2, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 0]
        let all = handshake + encodings + key + cut + text + resize
        var allowed = RFBClientFilter(clipboard: true)
        var got: [RFBClientFilter.Out] = []
        for b in all { got += try allowed.feed([b]) }
        let forwarded = got.compactMap { if case .forward(let b) = $0 { b } else { nil } }.flatMap { $0 }
        #expect(forwarded == handshake + encodings + key + cut)
        #expect(got.contains(.text("سلا")))
        #expect(got.contains(.resize(width: 1280, height: 800, scale: 2)))
        var denied = RFBClientFilter(clipboard: false)
        let out = try denied.feed(all).compactMap { if case .forward(let b) = $0 { b } else { nil } }.flatMap { $0 }
        #expect(out == handshake + encodings + key)
        var bad = RFBClientFilter(clipboard: true)
        #expect(throws: AgentMessage.Invalid.self) { try bad.feed(handshake + [7]) }
        var huge = RFBClientFilter(clipboard: true)
        #expect(throws: AgentMessage.Invalid.self) { try huge.feed(handshake + [6, 0, 0, 0, 0x7f, 0, 0, 0]) }
    }

    @Test func survivesRandomBytes() {
        for _ in 0..<1000 {
            var reader = AgentMessage.Reader()
            _ = try? reader.feed((0..<Int.random(in: 0..<40)).map { _ in UInt8.random(in: 0...255) })
            var filter = RFBClientFilter(clipboard: true)
            _ = try? filter.feed((0..<Int.random(in: 0..<60)).map { _ in UInt8.random(in: 0...255) })
        }
    }
}
