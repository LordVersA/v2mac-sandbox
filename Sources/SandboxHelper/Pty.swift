import AgentProtocol
import AppKit
import AVFoundation
import Virtualization

/// The pty bridge (plan §5 `pty`): `v2mac-pty` in Terminal connects to `pty.sock`, names a mini VM
/// and an app on one line, and from then on its bytes go unchanged to the agent's pty port and back.
@MainActor final class PtyServer {
    /// Open pty apps; V2Mac's quit prompt asks about them.
    private(set) var sessions = 0
    private var nextPort = AgentMessage.sessionPorts.lowerBound
    private let asks: PermissionAsk
    private let vm: SandboxVM
    private let gateway: Gateway
    private let retain: () -> Void
    private let store: StoreClient
    let socket: URL

    init(vm: SandboxVM, gateway: Gateway, store: StoreClient, root: URL, retain: @escaping () -> Void) {
        self.vm = vm
        self.gateway = gateway
        self.store = store
        self.retain = retain
        asks = PermissionAsk(gateway: gateway)
        socket = root.appendingPathComponent("pty.sock")
    }


    func start() {
        let path = socket.path
        unlink(path)
        let s = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { return log("pty socket path too long: \(path)") }
        withUnsafeMutableBytes(of: &addr.sun_path) { p in for (i, ch) in path.utf8.enumerated() { p[i] = ch } }
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        chmod(path, 0o600)
        guard s >= 0, bound == 0, listen(s, 8) == 0 else { return log("pty socket failed: errno \(errno)") }
        Thread.detachNewThread {
            while true {
                let c = accept(s, nil, nil)
                guard c >= 0 else { continue }
                Thread.detachNewThread {
                    guard let line = Self.readLine(c) else { close(c); return }
                    let words = line.split(separator: " ").map(String.init)
                    Task { @MainActor in await self.open(c, words) }
                }
            }
        }
    }

    private nonisolated static func readLine(_ fd: Int32) -> String? {
        var bytes: [UInt8] = []
        var b: UInt8 = 0
        while bytes.count < 256, read(fd, &b, 1) == 1 {
            if b == 0x0a { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(b)
        }
        return nil
    }

    private func open(_ c: Int32, _ words: [String]) async {
        func reject(_ text: String) {
            log("open \(words.joined(separator: " ")): \(text)")
            let bytes = Array("v2mac-pty: \(text)\r\n".utf8)
            _ = bytes.withUnsafeBytes { write(c, $0.baseAddress, $0.count) }
            close(c)
        }
        // pty: "<vm> <app>"; gui: "gui <vm> <app> <width> <height> <scale>"
        let gui = words.first == "gui"
        let ids = gui ? Array(words.dropFirst()) : words
        guard ids.count == (gui ? 5 : 2), let mini = gateway.vms.first(where: { $0.id == ids[0] }),
              let app = mini.apps.first(where: { $0.id == ids[1] }) ?? (ids[1] == InstalledApp.terminal.id ? .terminal : nil),
              (app.display == "gui") == gui
        else { return reject("this app is no longer in the sandbox.") }
        if let revoked = store.index?.revocation(of: app) {
            return reject("\(app.name) \(app.version) was withdrawn from the store (\(revoked.reason)). Update or remove it in the Sandbox window.")
        }
        var size: [String] = []
        if gui {
            guard let w = Int(ids[2]), let h = Int(ids[3]), let scale = Int(ids[4]),
                  (64...8192).contains(w), (64...8192).contains(h), [1, 2].contains(scale) else { return reject("bad window size.") }
            size = [String(w), String(h), String(scale)]
        }
        retain()
        var released = false
        func release() { if !released { released = true; vm.release() } }
        for _ in 0..<900 where !gateway.ready { try? await Task.sleep(for: .milliseconds(100)) }
        guard gateway.ready, let device = vm.socketDevice,
              await vm.call(.put(name: "plugin-\(mini.id)-\(app.id).argv", body: app.argvFile)) == .ok,
              await vm.call(.put(name: "plugin-\(mini.id)-\(app.id).env", body: app.envFile + (gateway.facts[mini.id]?.timezone.map { "TZ=\($0)\n" } ?? ""))) == .ok
        else { release(); return reject("the sandbox did not start.") }
        // Each asked permission gets its own vsock port while the app is open, so a connection names the
        // app the user is asked about; 0 tells the guest it isn't granted.
        var ports: [String: UInt32] = [:]
        var forwards: [SessionForward] = []
        for permission in PluginManifest.askedPermissions where app.allows(permission) && (permission == "ssh-agent") != gui {
            let port = nextPort
            nextPort = port == AgentMessage.sessionPorts.upperBound ? AgentMessage.sessionPorts.lowerBound : port + 1
            let serve: @Sendable (Int32) -> Void = switch permission {
            case "sound": MacAudio.play
            case "microphone": MacAudio.record
            default: SessionForward.sshAgent
            }
            let forward = SessionForward(ask: { [asks] in await asks.allowed(permission, app, in: mini) }, serve: serve)
            device.setSocketListener(forward.listener, forPort: port)
            ports[permission] = port
            forwards.append(forward)
        }
        let port = { String(ports[$0] ?? 0) }
        let flag = { $0 ? "1" : "0" }
        let clipboard = app.allows("clipboard")
        let open: AgentMessage = gui
            ? .gui([String(mini.index), mini.id, app.id, flag(mini.disposable), flag(app.allows("shared")), flag(clipboard && mini.pasteIn),
                    port("sound"), port("microphone")] + size + [app.image ?? "-"])
            : .pty([String(mini.index), mini.id, app.id, flag(mini.disposable), port("ssh-agent"), app.image ?? "-"])
        // The stub learns whether it may put the app's copies on the Mac's clipboard, and the title capsule.
        let header = gui ? Array("ok \(flag(clipboard && mini.copyOut)) \(capsule(mini))\n".utf8) : []
        sessions += 1
        let end = { @MainActor [weak self] in
            release()
            for port in ports.values { device.removeSocketListener(forPort: port) }
            _ = forwards // a listener holds its delegate weakly: keep them until here
            self?.sessions -= 1
        }
        device.connect(toPort: gui ? AgentMessage.guiPort : AgentMessage.ptyPort) { result in
            guard case .success(let connection) = result else {
                reject("the sandbox did not answer.")
                return DispatchQueue.main.async { MainActor.assumeIsolated { end() } }
            }
            let guest = dup(connection.fileDescriptor)
            connection.close()
            for bytes in [open.frame] { _ = bytes.withUnsafeBytes { write(guest, $0.baseAddress, $0.count) } }
            if !header.isEmpty { _ = header.withUnsafeBytes { write(c, $0.baseAddress, $0.count) } }
            RelayListener.pipe(c, guest) { DispatchQueue.main.async { MainActor.assumeIsolated { end() } } }
        }
    }

    /// "🛡 V2Mac Protected · Work · 🇩🇪 Frankfurt" (plan: title capsule), as it is when the window opens.
    private func capsule(_ mini: MiniVM) -> String {
        let place: String = switch gateway.exits[mini.id] ?? .unknown {
        case .ok(let place): place
        case .down: "Not connected"
        case .none: "Blocked"
        case .unknown: "Checking exit"
        }
        return "🛡 V2Mac Protected · \(mini.name) · \(place)"
    }

}

/// Asks the user the first time an open app uses a permission it was granted (`askedPermissions`),
/// unless its standing answer in the Sandbox window says Always Allow or Don't Allow. One question at a time.
@MainActor final class PermissionAsk {
    private let gateway: Gateway
    private var last: Task<Bool, Never>?

    init(gateway: Gateway) { self.gateway = gateway }

    func allowed(_ permission: String, _ app: InstalledApp, in mini: MiniVM) async -> Bool {
        let previous = last
        let next = Task { _ = await previous?.value; return self.prompt(permission, app.id, in: mini.id) }
        last = next
        return await next.value
    }

    private func prompt(_ permission: String, _ id: String, in vmID: String) -> Bool {
        // As it is now: an answer given meanwhile counts, and a removed app gets nothing.
        guard let mini = gateway.vms.first(where: { $0.id == vmID }), let app = mini.apps.first(where: { $0.id == id }), app.allows(permission) else { return false }
        if let answer = app.answers[permission] { return answer }
        let alert = NSAlert()
        alert.messageText = switch permission {
        case "sound": String(localized: "\(app.name) in \(mini.name) wants to play sound.")
        case "microphone": String(localized: "\(app.name) in \(mini.name) wants to use the microphone.")
        default: String(localized: "\(app.name) in \(mini.name) wants to use the SSH keys in your Mac's ssh-agent.")
        }
        alert.informativeText = String(localized: "Allow holds until the app is closed. Always Allow and Don't Allow can be changed in the app's menu in the Sandbox window.")
        alert.icon = NSWorkspace.shared.icon(forFile: StubApps.url(app, in: mini).path)
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Don't Allow")).keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: String(localized: "Always Allow"))
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: return true
        case .alertThirdButtonReturn: gateway.setAnswer(app, in: mini, permission, true); return true
        default: return false
        }
    }
}

/// One open app's use of an asked permission on its own vsock port: the guest connects when the app
/// uses it, the user is asked at the first connection (that answer holds while the app is open), and an
/// allowed connection goes to `serve`, which owns and closes it.
final class SessionForward: NSObject, VZVirtioSocketListenerDelegate, @unchecked Sendable {
    let listener = VZVirtioSocketListener()
    private let ask: @MainActor () async -> Bool
    private let serve: @Sendable (Int32) -> Void
    @MainActor private var answer: Task<Bool, Never>?

    init(ask: @escaping @MainActor () async -> Bool, serve: @escaping @Sendable (Int32) -> Void) {
        self.ask = ask
        self.serve = serve
        super.init()
        listener.delegate = self
    }

    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        let guest = dup(connection.fileDescriptor)
        connection.close()
        Task { @MainActor in
            if answer == nil { answer = Task { await ask() } }
            guard await answer!.value else { close(guest); return }
            serve(guest)
        }
        return true
    }

    /// The guest's end of an app's ssh-agent to the Mac's `SSH_AUTH_SOCK`.
    static let sshAgent: @Sendable (Int32) -> Void = { guest in
        guard let path = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], path.utf8.count < 104 else { close(guest); return }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { p in for (i, ch) in path.utf8.enumerated() { p[i] = ch } }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
        guard ok else { close(s); close(guest); return }
        RelayListener.pipe(guest, s)
    }
}

/// An app's sound as the guest's bridge carries it (rootfs `sandbox.sh` gui): raw 48 kHz 16-bit stereo,
/// to the Mac's speakers or from its microphone, until either side closes.
enum MacAudio {
    static let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: true)!

    static func play(_ fd: Int32) {
        Thread.detachNewThread {
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            defer { player.stop(); engine.stop(); close(fd) }
            guard (try? engine.start()) != nil else { return log("could not start the Mac's sound output") }
            player.play()
            let frames = 960 // 20 ms
            var bytes = [UInt8](repeating: 0, count: frames * 4)
            while readFull(fd, &bytes), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) {
                buffer.frameLength = AVAudioFrameCount(frames)
                bytes.withUnsafeBytes { raw in
                    let samples = raw.bindMemory(to: Int16.self)
                    for i in 0..<frames {
                        buffer.floatChannelData![0][i] = Float(Int16(littleEndian: samples[2 * i])) / 32768
                        buffer.floatChannelData![1][i] = Float(Int16(littleEndian: samples[2 * i + 1])) / 32768
                    }
                }
                player.scheduleBuffer(buffer)
            }
        }
    }

    /// The Mac's microphone is open only while this runs.
    static func record(_ fd: Int32) {
        Thread.detachNewThread {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, let converter = AVAudioConverter(from: format, to: wire) else {
                close(fd)
                return log("no microphone, or V2Mac Sandbox may not use it (System Settings → Privacy & Security → Microphone)")
            }
            if format.channelCount == 1 { converter.channelMap = [0, 0] }
            input.installTap(onBus: 0, bufferSize: 4800, format: format) { buffer, _ in
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 48000 / format.sampleRate) + 64
                guard let out = AVAudioPCMBuffer(pcmFormat: wire, frameCapacity: capacity) else { return }
                nonisolated(unsafe) var fed = false
                converter.convert(to: out, error: nil) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true
                    status.pointee = .haveData
                    return buffer
                }
                _ = write(fd, out.int16ChannelData![0], Int(out.frameLength) * 4)
            }
            guard (try? engine.start()) != nil else { close(fd); return log("could not start the Mac's microphone") }
            // The guest sends nothing; its close ends the recording.
            var byte: UInt8 = 0
            while read(fd, &byte, 1) > 0 {}
            input.removeTap(onBus: 0)
            engine.stop()
            close(fd)
        }
    }

    private static func readFull(_ fd: Int32, _ bytes: inout [UInt8]) -> Bool {
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return false }
            off += n
        }
        return true
    }
}
