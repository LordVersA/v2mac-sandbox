import Testing
@testable import AgentProtocol

@Suite struct AgentProtocolTests {
    @Test func messagesRoundTripAcrossSplitFrames() throws {
        let sent: [AgentMessage] = [.hello(version: 1), .shutdown, .ok]
        let bytes = sent.flatMap(\.frame)
        var reader = AgentMessage.Reader()
        var got: [AgentMessage] = []
        for start in stride(from: 0, to: bytes.count, by: 3) {
            got += try reader.feed(bytes[start..<min(start + 3, bytes.count)])
        }
        #expect(got == sent)
    }

    @Test func refusesUnknownAndOversizedFrames() {
        for text in ["reboot", "hello", "hello x", "shutdown now", ""] {
            var reader = AgentMessage.Reader()
            let body = Array(text.utf8)
            #expect(throws: AgentMessage.Invalid.self) { try reader.feed([0, 0, 0, UInt8(body.count)] + body) }
        }
        var reader = AgentMessage.Reader()
        #expect(throws: AgentMessage.Invalid.self) { try reader.feed([0, 1, 0, 1]) }
    }

    @Test func survivesRandomBytes() {
        for _ in 0..<1000 {
            var reader = AgentMessage.Reader()
            _ = try? reader.feed((0..<Int.random(in: 0..<40)).map { _ in UInt8.random(in: 0...255) })
        }
    }
}
