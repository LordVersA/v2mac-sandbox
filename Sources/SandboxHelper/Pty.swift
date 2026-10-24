import AgentProtocol
import Foundation
import Virtualization

/// The pty bridge (plan §5 `pty`): `v2mac-pty` in Terminal connects to `pty.sock`, names a mini VM
/// and an app on one line, and from then on its bytes go unchanged to the agent's pty port and back.
@MainActor final class PtyServer {
    /// Open pty apps; V2Mac's quit prompt asks about them.
    private(set) var sessions = 0
    private var sshSessions = 0 { didSet { sshChanged(oldValue) } }
    private let ssh = SSHAgentForward()
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
        let withSSH = !gui && app.allows("ssh-agent")
        let flag = { $0 ? "1" : "0" }
        let clipboard = app.allows("clipboard")
        let open: AgentMessage = gui
            ? .gui([String(mini.index), mini.id, app.id, flag(mini.disposable), flag(app.allows("shared")), flag(clipboard && mini.pasteIn)] + size + [app.image ?? "-"])
            : .pty([String(mini.index), mini.id, app.id, flag(mini.disposable), flag(withSSH), app.image ?? "-"])
        // The stub learns whether it may put the app's copies on the Mac's clipboard, and the title capsule.
        let header = gui ? Array("ok \(flag(clipboard && mini.copyOut)) \(capsule(mini))\n".utf8) : []
        sessions += 1
        if withSSH { sshSessions += 1 }
        let end = { @MainActor [weak self] in
            release()
            guard let self else { return }
            self.sessions -= 1
            if withSSH { self.sshSessions -= 1 }
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

    private func sshChanged(_ old: Int) {
        guard let device = vm.socketDevice else { return }
        if old == 0, sshSessions > 0 { device.setSocketListener(ssh.listener, forPort: AgentMessage.sshAgentPort) }
        if old > 0, sshSessions == 0 { device.removeSocketListener(forPort: AgentMessage.sshAgentPort) }
    }
}

/// The guest's end of an approved app's ssh-agent (vsock 1027) to the Mac's `SSH_AUTH_SOCK`.
final class SSHAgentForward: NSObject, VZVirtioSocketListenerDelegate, @unchecked Sendable {
    let listener = VZVirtioSocketListener()
    override init() { super.init(); listener.delegate = self }

    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        guard let path = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], path.utf8.count < 104 else { return false }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { p in for (i, ch) in path.utf8.enumerated() { p[i] = ch } }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
        guard ok else { close(s); return false }
        let guest = dup(connection.fileDescriptor)
        connection.close()
        RelayListener.pipe(guest, s)
        return true
    }
}
