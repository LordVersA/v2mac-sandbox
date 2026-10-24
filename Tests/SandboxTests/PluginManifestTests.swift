import Foundation
import Testing
@testable import SandboxHelper
import V2MacCore

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

    @Test func takesAnSVGIconAndRefusesAnythingElse() throws {
        let svg = #"<svg xmlns='http://www.w3.org/2000/svg' width='8' height='8'><rect width='8' height='8' fill='red'/></svg>"#
        var manifest = try decode(Self.good)
        manifest.iconSvg = svg
        try manifest.validate()
        #expect(InstalledApp(manifest, granted: []).iconSvg == svg)
        #expect(try StubApps.icon(name: "Hello", hue: 0.5, svg: svg).count > 0)
        for bad in ["not an image", "<svg" + String(repeating: " ", count: PluginManifest.maxIcon) + "/>"] {
            manifest.iconSvg = bad
            #expect(throws: PluginManifest.Invalid.self) { try manifest.validate() }
        }
    }

    @Test func quotesForTheLaunchCommand() {
        #expect(StubApps.quote("it's a/b") == #"'it'\''s a/b'"#)
    }
}

@Suite struct ExitFactsTests {
    let tab = "# comment\nDE\t+5230+01322\tEurope/Berlin\tmost of Germany\nDE\t+4742+00841\tEurope/Busingen\tBusingen\nIR\t+3540+05126\tAsia/Tehran\n"

    @Test func picksTheCitysZoneElseTheCountrys() {
        let busingen = ExitFacts(ExitInfo(ip: "1.2.3.4", countryCode: "DE", city: "Busingen"), zoneTab: tab)
        #expect(busingen.timezone == "Europe/Busingen")
        let frankfurt = ExitFacts(ExitInfo(ip: "1.2.3.4", countryCode: "DE", city: "Frankfurt am Main"), zoneTab: tab)
        #expect(frankfurt.timezone == "Europe/Berlin")
        #expect(frankfurt.latitude == 52.5)
        #expect(ExitFacts(ExitInfo(ip: "5.6.7.8"), zoneTab: tab).timezone == nil)
    }
}
