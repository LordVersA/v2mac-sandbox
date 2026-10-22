import Foundation
import Testing
@testable import SandboxHelper

@Suite struct PluginManifestTests {
    static let good = #"{"api":1,"id":"hello-pty","name":"Hello","version":"1.0","display":"pty","launch":{"cmd":["bash","-l"],"env":{"GREETING":"hi there"}},"permissions":["ssh-agent"]}"#

    func decode(_ json: String) throws -> PluginManifest { try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8)) }

    @Test func acceptsAGoodManifestAndBuildsLaunchFiles() throws {
        let manifest = try decode(Self.good)
        try manifest.validate()
        let app = InstalledApp(manifest, granted: [])
        #expect(app.argvFile == "bash\0-l\0")
        #expect(app.envFile == "GREETING=hi there\n")
        #expect(app.granted.isEmpty)
    }

    @Test func refusesWhatTheRuntimeCannotTrust() throws {
        let bad = [
            (#""api":1"#, #""api":2"#), (#""id":"hello-pty""#, #""id":"a;b""#), (#""id":"hello-pty""#, #""id":"../x""#),
            (#""display":"pty""#, #""display":"web""#), (#"["bash","-l"]"#, "[]"), (#""GREETING""#, #""A B""#),
            (#""hi there""#, #""a\nb""#), (#"["ssh-agent"]"#, #"["camera"]"#),
        ]
        for (from, to) in bad {
            #expect(throws: PluginManifest.Invalid.self) { try decode(Self.good.replacingOccurrences(of: from, with: to)).validate() }
        }
    }

    @Test func quotesForTheLaunchCommand() {
        #expect(StubApps.quote("it's a/b") == #"'it'\''s a/b'"#)
    }
}
