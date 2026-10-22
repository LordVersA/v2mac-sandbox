import AgentProtocol
import AppKit
import ImageIO

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
        guard ["pty", "gui"].contains(display) else { throw Invalid("plugin.json has an unknown display.") }
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
    /// `pty` or `gui` (plan §6).
    var display = "pty"
    var cmd: [String]
    var env: [String: String]
    var granted: [String]
    /// Sideloaded from a folder, not from the signed store.
    var unverified = true

    init(_ manifest: PluginManifest, granted: [String]) {
        id = manifest.id
        name = manifest.name
        version = manifest.version
        display = manifest.display
        cmd = manifest.launch.cmd
        env = manifest.launch.env ?? [:]
        self.granted = granted
    }

    func allows(_ permission: String) -> Bool { granted.contains(permission) }

    /// `put` bodies for sandbox.sh `app`.
    var argvFile: String { cmd.map { $0 + "\0" }.joined() }
    var envFile: String { env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)\n" }.joined() }
}

extension InstalledApp {
    // Apps installed before M4 have no `display`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(String.self, forKey: .version)
        display = try c.decodeIfPresent(String.self, forKey: .display) ?? "pty"
        cmd = try c.decode([String].self, forKey: .cmd)
        env = try c.decode([String: String].self, forKey: .env)
        granted = try c.decode([String].self, forKey: .granted)
        unverified = try c.decodeIfPresent(Bool.self, forKey: .unverified) ?? true
    }
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
            "CFBundleIconFile": "AppIcon", "NSHighResolutionCapable": true,
            // Read by the stub: where the helper listens and which app of which mini VM this is.
            "V2MacSocket": socket.path, "V2MacVM": vm.id, "V2MacApp": app.id, "V2MacDisplay": app.display,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        try icon(name: app.name, hue: vm.hue).write(to: resources.appendingPathComponent("AppIcon.icns"))
        if app.display == "pty" {
            let words = [helper.appendingPathComponent("v2mac-pty").path, socket.path, vm.id, app.id, "\(app.name) — \(vm.name)"]
            let command = resources.appendingPathComponent("launch.command")
            try ("#!/bin/sh\nexec " + words.map(quote).joined(separator: " ") + "\n").write(to: command, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        }
        guard run("/usr/bin/codesign", ["--force", "--sign", "-", bundle.path]) else { throw PluginManifest.Invalid("Could not sign \(bundle.lastPathComponent).") }
        _ = run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", bundle.path])
    }

    static func remove(_ app: InstalledApp, in vm: MiniVM) {
        let bundle = url(app, in: vm)
        _ = run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-u", bundle.path])
        try? FileManager.default.removeItem(at: bundle)
    }

    /// The app's initial on a rounded square in the mini VM's colour, with a shield (plan: icon tinted
    /// in the VM's colour). shortcut: plugins have no icon of their own until store layers carry one (M5).
    static func icon(name: String, hue: Double) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "com.apple.icns" as CFString, 6, nil) else { throw PluginManifest.Invalid("no icns writer") }
        for size in [16, 32, 64, 128, 256, 512, 1024] where size != 64 {
            let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
                let unit = r.width / 1024
                NSColor(hue: hue, saturation: 0.65, brightness: 0.85, alpha: 1).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 100 * unit, dy: 100 * unit), xRadius: 185 * unit, yRadius: 185 * unit).fill()
                let letter = String(name.prefix(1)).uppercased() as NSString
                let font = NSFont.systemFont(ofSize: 520 * unit, weight: .bold)
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
                let box = letter.size(withAttributes: attributes)
                letter.draw(at: NSPoint(x: (r.width - box.width) / 2, y: (r.height - box.height) / 2 + 20 * unit), withAttributes: attributes)
                if let shield = NSImage(systemSymbolName: "checkmark.shield.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 200 * unit, weight: .bold).applying(.init(paletteColors: [.white, .systemGreen]))) {
                    shield.draw(in: NSRect(x: r.width - 330 * unit, y: 130 * unit, width: 200 * unit, height: 230 * unit))
                }
                return true
            }
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            CGImageDestinationAddImage(dest, cg, nil)
        }
        guard CGImageDestinationFinalize(dest) else { throw PluginManifest.Invalid("Could not draw the icon.") }
        return data as Data
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
