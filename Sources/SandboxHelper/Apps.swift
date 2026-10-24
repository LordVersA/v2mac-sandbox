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
    /// Shown in the store window.
    var publisher: String?
    var description: String?
    var changelog: String?
    var securityNotes: String?
    /// Store plugins only (plan §6): the OCI image archive(s), pinned by SHA-256.
    var layers: [Layer]?
    var source: Source?
    /// The released base image it is built on (plan §7), exactly as `bases.json` lists it.
    var from: String?
    /// The icon's filename in the plugin folder or release; `iconSvg` is its text, which the store
    /// copies into the signed index and a sideload reads from the folder.
    var icon: String?
    var iconSvg: String?

    struct Layer: Codable, Equatable, Sendable {
        var url: URL
        var sha256: String
        var size: Int64
    }

    struct Source: Codable, Equatable, Sendable {
        var repo: String
        var commit: String
    }

    static let api = 1
    static let knownPermissions = ["clipboard", "shared", "ssh-agent", "sound", "microphone"]
    /// Granted at install, and asked again each time an open app first uses them.
    static let askedPermissions = ["sound", "microphone", "ssh-agent"]

    struct Invalid: Error, LocalizedError {
        var errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    static func load(folder: URL) throws -> PluginManifest {
        let data: Data
        do { data = try Data(contentsOf: folder.appendingPathComponent("plugin.json")) } catch { throw Invalid("The folder has no plugin.json.") }
        let manifest: PluginManifest
        do { manifest = try JSONDecoder().decode(PluginManifest.self, from: data) } catch { throw Invalid("plugin.json is not a valid plugin manifest.") }
        var checked = manifest
        if let icon = manifest.icon, !icon.contains("/"), !icon.hasPrefix("."),
           let data = try? Data(contentsOf: folder.appendingPathComponent(icon)) {
            checked.iconSvg = String(data: data, encoding: .utf8)
        }
        try checked.validate()
        return checked
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
        guard iconSvg.map({ $0.utf8.count <= Self.maxIcon && Self.image($0) != nil }) ?? true else { throw Invalid("\(name)'s icon is not an SVG image of at most 64 KB.") }
    }

    static let maxIcon = 64 << 10

    /// An icon's SVG as an image (NSImage draws SVG without scripts or external files).
    static func image(_ svg: String) -> NSImage? {
        guard svg.contains("<svg"), let image = NSImage(data: Data(svg.utf8)), image.isValid else { return nil }
        return image
    }

    /// A store plugin must also bring its files: one https archive of its own layers, with a hash and a size.
    func validateForStore(bases: Set<String> = Store.bases) throws {
        try validate()
        guard let layers, layers.count == 1, source != nil else { throw Invalid("\(id) must bring exactly one archive.") }
        guard let from, bases.contains(from) else { throw Invalid("\(id) is not built on a released base image.") }
        for layer in layers {
            guard layer.url.scheme == "https" || Store.allowsLocal(layer.url), layer.sha256.count == 64,
                  layer.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }), (1...(4 << 30)).contains(layer.size)
            else { throw Invalid("\(id) has a bad layer.") }
        }
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
    /// The loaded image's id for a store plugin; nil runs on the VM's own root (sideloads).
    var image: String?
    var source: PluginManifest.Source?
    var layers: [PluginManifest.Layer] = []
    var iconSvg: String?
    /// The user's standing answer per asked permission: true Always Allow, false Don't Allow; none asks.
    var answers: [String: Bool] = [:]
    /// The Debian package it came from (Linux Packages); it runs on the shared package root.
    var package: String?

    init(_ manifest: PluginManifest, granted: [String]) {
        id = manifest.id
        name = manifest.name
        version = manifest.version
        display = manifest.display
        cmd = manifest.launch.cmd
        env = manifest.launch.env ?? [:]
        iconSvg = manifest.iconSvg
        self.granted = granted
    }

    func allows(_ permission: String) -> Bool { granted.contains(permission) }

    /// sandbox.sh's image word for the shared Debian package root.
    static let packagesImage = "pkgs"

    /// A window or terminal app a Debian package brings: one "app" line of `sandbox.sh pkg-install`
    /// (`app <gui|pty> <desktop file> <Name> <Exec>`, tab-separated).
    init?(package: String, line: Substring, granted: [String]) {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 5, f[0] == "app", ["gui", "pty"].contains(f[1]), !f[3].isEmpty, !f[4].contains("\0") else { return nil }
        let file = f[2].hasSuffix(".desktop") ? String(f[2].dropLast(8)) : f[2]
        let id = "deb-" + String(file.map { AgentMessage.isWord(String($0)) ? $0 : "-" }.prefix(60))
        // The desktop entry's field codes (%U for URLs to open…) have nothing to fill in at launch.
        let exec = f[4].replacingOccurrences(of: "%%", with: "\u{1}").replacing(/%[A-Za-z]/, with: "").replacingOccurrences(of: "\u{1}", with: "%")
        // Under sway's forced fullscreen browsers hide their tabs (as F11); the only window fills the screen anyway.
        let cmd = f[1] == "gui"
            ? "SWAYSOCK=$(ls \"$XDG_RUNTIME_DIR\"/sway-ipc.*.sock | head -n1) swaymsg 'for_window [all] fullscreen disable' >/dev/null; exec \(exec)"
            : "exec \(exec)"
        self.init(PluginManifest(api: 1, id: id, name: String(f[3].prefix(64)), version: "", display: f[1],
                                 launch: .init(cmd: ["/bin/sh", "-c", cmd])), granted: granted)
        image = Self.packagesImage
        self.package = package
    }

    /// Every mini VM's own shell, with nothing to install: the VM's root and no permissions. Its id
    /// starts with "." so no plugin can take it (plugin ids can't).
    static let terminal = InstalledApp(PluginManifest(api: 1, id: ".terminal", name: "Terminal", version: "", display: "pty",
                                                      launch: .init(cmd: ["/bin/bash", "-l"])), granted: [])

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
        image = try c.decodeIfPresent(String.self, forKey: .image)
        source = try c.decodeIfPresent(PluginManifest.Source.self, forKey: .source)
        layers = try c.decodeIfPresent([PluginManifest.Layer].self, forKey: .layers) ?? []
        iconSvg = try c.decodeIfPresent(String.self, forKey: .iconSvg)
        answers = try c.decodeIfPresent([String: Bool].self, forKey: .answers) ?? [:]
        package = try c.decodeIfPresent(String.self, forKey: .package)
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
        // The stub's own texts: the helper's compiled String Catalog.
        for lproj in (try? fm.contentsOfDirectory(at: Bundle.main.resourceURL!, includingPropertiesForKeys: nil)) ?? [] where lproj.pathExtension == "lproj" {
            try fm.copyItem(at: lproj, to: resources.appendingPathComponent(lproj.lastPathComponent))
        }
        try icon(name: app.name, hue: vm.hue, svg: app.iconSvg).write(to: resources.appendingPathComponent("AppIcon.icns"))
        if app.display == "pty" {
            let words = [helper.appendingPathComponent("v2mac-pty").path, socket.path, vm.id, app.id, "\(app.name) — \(vm.name)"]
            let command = resources.appendingPathComponent("launch.command")
            try ("#!/bin/sh\nexec " + words.map(quote).joined(separator: " ") + "\n").write(to: command, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        }
        guard run("/usr/bin/codesign", ["--force", "--sign", "-", bundle.path]) else { throw PluginManifest.Invalid("Could not sign \(bundle.lastPathComponent).") }
        _ = run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", bundle.path])
    }

    /// Opens the mini VM's built-in terminal (`InstalledApp.terminal`) in the user's Terminal.
    static func openTerminal(in vm: MiniVM, socket: URL, folder: URL) throws {
        let pty = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/v2mac-pty").path
        let command = folder.appendingPathComponent("terminal-\(vm.id).command")
        let words = [pty, socket.path, vm.id, InstalledApp.terminal.id, "Terminal — \(vm.name)"]
        try ("#!/bin/sh\nexec " + words.map(quote).joined(separator: " ") + "\n").write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        NSWorkspace.shared.open(command)
    }

    static func remove(_ app: InstalledApp, in vm: MiniVM) {
        let bundle = url(app, in: vm)
        _ = run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-u", bundle.path])
        try? FileManager.default.removeItem(at: bundle)
    }

    /// The plugin's icon (else its initial) on a rounded square in the mini VM's colour, with a shield
    /// (plan: icon tinted in the VM's colour).
    static func icon(name: String, hue: Double, svg: String? = nil) throws -> Data {
        let own = svg.flatMap(PluginManifest.image)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "com.apple.icns" as CFString, 6, nil) else { throw PluginManifest.Invalid("no icns writer") }
        for size in [16, 32, 64, 128, 256, 512, 1024] where size != 64 {
            let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
                let unit = r.width / 1024
                NSColor(hue: hue, saturation: 0.65, brightness: 0.85, alpha: 1).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 100 * unit, dy: 100 * unit), xRadius: 185 * unit, yRadius: 185 * unit).fill()
                if let own {
                    // Inset so the mini VM's colour stays visible as a frame around it.
                    own.draw(in: r.insetBy(dx: 170 * unit, dy: 170 * unit))
                } else {
                    let letter = String(name.prefix(1)).uppercased() as NSString
                    let font = NSFont.systemFont(ofSize: 520 * unit, weight: .bold)
                    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
                    let box = letter.size(withAttributes: attributes)
                    letter.draw(at: NSPoint(x: (r.width - box.width) / 2, y: (r.height - box.height) / 2 + 20 * unit), withAttributes: attributes)
                }
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
