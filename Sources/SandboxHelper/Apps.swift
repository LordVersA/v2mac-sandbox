import AgentProtocol
import Foundation

/// `plugin.json` (plan §6, plugin API v1). A plugin is untrusted input: everything the runtime uses
/// from it is checked here.
struct PluginManifest: Decodable, Equatable {
    struct Launch: Decodable, Equatable {
        var cmd: [String]
        var env: [String: String]?
    }

    var api: Int
    var id: String
    var name: String
    var version: String
    var display: String
    var launch: Launch
    var permissions: [String]?

    static let api = 1
    static let knownPermissions = ["clipboard", "shared", "ssh-agent"]

    struct Invalid: Error, LocalizedError {
        var errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    static func load(folder: URL) throws -> PluginManifest {
        let data: Data
        do { data = try Data(contentsOf: folder.appendingPathComponent("plugin.json")) } catch { throw Invalid("The folder has no plugin.json.") }
        let manifest: PluginManifest
        do { manifest = try JSONDecoder().decode(PluginManifest.self, from: data) } catch { throw Invalid("plugin.json is not a valid plugin manifest.") }
        try manifest.validate()
        return manifest
    }

    func validate() throws {
        guard api <= Self.api else { throw Invalid("\(name) needs a newer V2Mac.") }
        guard api >= 1, AgentMessage.isWord(id), !id.hasPrefix("."), !name.isEmpty, name.count <= 64 else { throw Invalid("plugin.json has a bad api, id or name.") }
        // shortcut: gui apps need the window display (M4).
        guard display == "pty" else { throw Invalid("\(name) is a window app; this sandbox runs only terminal apps so far.") }
        guard !launch.cmd.isEmpty, launch.cmd.allSatisfy({ !$0.contains("\0") }) else { throw Invalid("plugin.json has no launch command.") }
        for (key, value) in launch.env ?? [:] {
            let keyOK = key.first.map { $0 == "_" || $0.isASCII && $0.isLetter } == true
                && key.allSatisfy { $0 == "_" || $0.isASCII && ($0.isLetter || $0.isNumber) }
            guard keyOK, !value.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else { throw Invalid("plugin.json has a bad environment variable \(key).") }
        }
        guard (permissions ?? []).allSatisfy(Self.knownPermissions.contains) else { throw Invalid("plugin.json asks for an unknown permission.") }
    }
}

/// A plugin installed in one mini VM, with the permissions the user approved (plan §6: the runtime
/// gives only these).
struct InstalledApp: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var version: String
    var cmd: [String]
    var env: [String: String]
    var granted: [String]
    /// Sideloaded from a folder, not from the signed store.
    var unverified = true

    init(_ manifest: PluginManifest, granted: [String]) {
        id = manifest.id
        name = manifest.name
        version = manifest.version
        cmd = manifest.launch.cmd
        env = manifest.launch.env ?? [:]
        self.granted = granted
    }

    /// `put` bodies for sandbox.sh `app`.
    var argvFile: String { cmd.map { $0 + "\0" }.joined() }
    var envFile: String { env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)\n" }.joined() }
}

/// The generated Mac app per app per mini VM (plan §5): a copy of the helper's stub with its own
/// Info.plist, ad-hoc signed and registered. For a pty app the stub opens `launch.command`, which runs
/// `v2mac-pty` in the user's Terminal.
enum StubApps {
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/V2Mac Sandbox", isDirectory: true)
    }

    static func url(_ app: InstalledApp, in vm: MiniVM) -> URL {
        func safe(_ s: String) -> String { s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") }
        return folder.appendingPathComponent("\(safe(app.name)) — \(safe(vm.name)).app", isDirectory: true)
    }

    static func bundleID(_ app: InstalledApp, in vm: MiniVM) -> String { "io.github.lordversa.v2mac.sandbox.\(vm.id).\(app.id)" }

    static func make(_ app: InstalledApp, in vm: MiniVM, socket: URL) throws {
        let fm = FileManager.default
        let bundle = url(app, in: vm)
        try? fm.removeItem(at: bundle)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS")
        try fm.copyItem(at: helper.appendingPathComponent("v2mac-stub"), to: macOS.appendingPathComponent("stub"))
        let plist: [String: Any] = [
            "CFBundleExecutable": "stub", "CFBundleIdentifier": bundleID(app, in: vm),
            "CFBundleName": "\(app.name) — \(vm.name)", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": app.version, "LSMinimumSystemVersion": "26.0",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let words = [helper.appendingPathComponent("v2mac-pty").path, socket.path, vm.id, app.id, "\(app.name) — \(vm.name)"]
        let command = resources.appendingPathComponent("launch.command")
        try ("#!/bin/sh\nexec " + words.map(quote).joined(separator: " ") + "\n").write(to: command, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        guard run("/usr/bin/codesign", ["--force", "--sign", "-", bundle.path]) else { throw PluginManifest.Invalid("Could not sign \(bundle.lastPathComponent).") }
        _ = run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", bundle.path])
    }

    static func remove(_ app: InstalledApp, in vm: MiniVM) {
        let bundle = url(app, in: vm)
        _ = run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-u", bundle.path])
        try? FileManager.default.removeItem(at: bundle)
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func run(_ tool: String, _ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
