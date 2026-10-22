import AgentProtocol
import Foundation
import Observation
import V2MacCore

/// Mini VMs and their exits (plan §4): the sandbox core on the host, the vsock relays, and through
/// the agent the gateway netns, xray-in-vm and one pod per mini VM. Every change runs in order.
@MainActor @Observable final class Gateway {
    enum ExitStatus: Equatable {
        case unknown, none, down
        case ok(String)
    }

    private(set) var vms: [MiniVM] = []
    private(set) var servers: [SandboxLink.Server] = []
    private(set) var activeServer: String?
    private(set) var exits: [String: ExitStatus] = [:]
    /// The mini VMs are set up in the running VM.
    private(set) var ready = false

    var corePath: URL?
    /// Asks V2Mac for a server's outbound; the answer comes back through `received`.
    @ObservationIgnored var requestOutbound: (String) -> Void = { _ in }
    @ObservationIgnored var notice: (String) -> Void = { _ in }

    @ObservationIgnored private let vm: SandboxVM
    @ObservationIgnored private let root: URL
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var pending: [String: [CheckedContinuation<JSONValue?, Never>]] = [:]
    @ObservationIgnored private var core: CoreRunner?
    @ObservationIgnored private var ports: [String: SandboxConfig.Ports] = [:]
    @ObservationIgnored private var apiPort = 0
    @ObservationIgnored private let checkPassword = UUID().uuidString
    @ObservationIgnored private var relays: [Int: RelayListener] = [:]
    @ObservationIgnored private var booted = false
    @ObservationIgnored private var inGuest: Set<String> = []
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var report: [String] = []

    private var store: URL { root.appendingPathComponent("vms.json") }

    init(vm: SandboxVM, root: URL) {
        self.vm = vm
        self.root = root
        vms = (try? JSONDecoder().decode([MiniVM].self, from: Data(contentsOf: root.appendingPathComponent("vms.json")))) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(vms) else { return }
        FileManager.default.createFile(atPath: store.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    /// `enqueue` for a step with a result; nil-equivalent when the VM isn't up.
    private func enqueueResult(_ body: @escaping @MainActor () async -> (ok: Bool, output: String)) -> Task<(ok: Bool, output: String), Never> {
        nonisolated(unsafe) var result = (ok: false, output: "the sandbox is not running")
        let done = enqueue { result = await body() }
        return Task { await done.value; return result }
    }

    /// Runs `body` after every earlier change, once the VM is up.
    @discardableResult private func enqueue(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = work
        let task = Task {
            await previous?.value
            for _ in 0..<600 where vm.state == .booting { try? await Task.sleep(for: .milliseconds(100)) }
            guard vm.state == .running else { return }
            await body()
        }
        work = task
        return task
    }

    // MARK: VM and link events

    func vmStateChanged(_ state: SandboxVM.State) {
        switch state {
        case .running: enqueue { await self.apply() }
        case .stopped, .stopping:
            ready = false
            booted = false
            inGuest = []
            relays = [:]
            watch?.cancel()
            Task { await core?.stop() }
            exits = [:]
        case .booting: break
        }
    }

    func serversChanged(_ list: [SandboxLink.Server], active: String?) {
        let first = servers.isEmpty
        servers = list
        activeServer = active
        guard !first else { return }
        // TUN mode or the network may have changed the binding: hand every exit out again.
        enqueue {
            guard self.ready else { return }
            for vm in self.vms where vm.exit != nil { await self.swapExit(vm) }
        }
    }

    func received(id: String, json: String?) {
        let value = json.flatMap { try? JSONValue.parse(Data($0.utf8)) }
        pending.removeValue(forKey: id)?.forEach { $0.resume(returning: value) }
    }

    private func outbound(for server: String) async -> JSONValue? {
        await withCheckedContinuation { continuation in
            pending[server, default: []].append(continuation)
            if pending[server]?.count == 1 { requestOutbound(server) }
            Task {
                try? await Task.sleep(for: .seconds(10))
                self.pending.removeValue(forKey: server)?.forEach { $0.resume(returning: nil) }
            }
        }
    }

    // MARK: Setup

    private func run(_ words: [String]) async -> (ok: Bool, output: String) {
        guard case .result(let status, let output)? = await vm.call(.run(words)) else {
            log("sandbox.sh \(words.joined(separator: " ")): no answer from the agent")
            return (false, "no answer from the agent")
        }
        if status != 0 { log("sandbox.sh \(words.joined(separator: " ")): \(status) \(output)") }
        return (status == 0, output)
    }

    /// Brings host and guest in line with `vms`: sandbox core (restarted), relays, gateway rules,
    /// xray-in-vm and any pod not yet made in this VM run.
    private func apply() async {
        updateShares()
        guard let corePath, let device = vm.socketDevice else { return log("no core path or vsock device yet") }
        if !booted {
            guard await run(["boot"]).ok else { return }
            booted = true
        }
        var outbounds: [String: JSONValue] = [:]
        for mini in vms {
            guard let exit = mini.exit else { continue }
            outbounds[mini.id] = await outbound(for: exit)
            if outbounds[mini.id] == nil { log("no outbound from V2Mac for \(mini.name)'s exit: blocked") }
        }
        do {
            let free = try PortUtil.freePorts(1 + 2 * vms.count)
            apiPort = free[0]
            ports = Dictionary(uniqueKeysWithValues: vms.enumerated().map { ($1.id, .init(inbound: free[1 + 2 * $0], check: free[2 + 2 * $0])) })
            let core = self.core ?? CoreRunner(executable: corePath, assetDirectory: root.appendingPathComponent("core"),
                                              runDirectory: root.appendingPathComponent("core/run"))
            self.core = core
            await core.stop()
            try await core.start(config: SandboxConfig.hostCore(vms: vms, ports: ports, outbounds: outbounds, apiPort: apiPort, checkPassword: checkPassword),
                                 readyPort: apiPort)
        } catch {
            return log("sandbox core did not start: \(error.localizedDescription)")
        }
        for mini in vms {
            let port = ports[mini.id]!.inbound
            if let relay = relays[mini.index] { relay.port = port; continue }
            let relay = RelayListener(port: port)
            device.setSocketListener(relay.listener, forPort: UInt32(mini.relayPort))
            relays[mini.index] = relay
        }
        for index in relays.keys where !vms.contains(where: { $0.index == index }) {
            device.removeSocketListener(forPort: UInt32(11000 + index))
            relays[index] = nil
        }
        guard let xray = try? SandboxConfig.guestXray(vms: vms).data(),
              await vm.call(.put(name: "xray.json", body: String(decoding: xray, as: UTF8.self))) == .ok,
              await vm.call(.put(name: "gateway.nft", body: SandboxConfig.gatewayNFT(vms: vms))) == .ok,
              await run(["gateway"] + vms.map { String($0.index) }).ok else { return log("gateway setup failed") }
        for mini in vms where !inGuest.contains(mini.id) {
            if await run(["vm-add", String(mini.index), mini.id, mini.disposable ? "1" : "0"]).ok { inGuest.insert(mini.id) }
        }
        ready = true
        log("gateway ready with \(vms.count) mini VMs")
        await checkExits()
        watch?.cancel()
        watch = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                if !Task.isCancelled { self.enqueue { await self.checkExits() } }
            }
        }
    }

    // MARK: Mini VM actions (plan M2.4)

    /// Adds a mini VM (Empty, or Clone of `source`); returns it before it is set up in the VM.
    @discardableResult func add(cloning source: MiniVM? = nil, name: String? = nil) -> MiniVM? {
        let name = name ?? source.map { "\($0.name) copy" } ?? "Mini VM \(vms.count + 1)"
        guard var mini = MiniVM.new(name: name, exit: source?.exit ?? activeServer, taken: vms) else { return nil }
        mini.apps = source?.apps ?? []
        enqueue {
            if let source, !(await self.run(["clone", source.id, mini.id]).ok) { return }
            for app in mini.apps { try? StubApps.make(app, in: mini, socket: self.ptySocket) }
            self.vms.append(mini)
            self.save()
            await self.apply()
        }
        return mini
    }

    func delete(_ mini: MiniVM) {
        enqueue {
            guard await self.run(["vm-del", String(mini.index), mini.id]).ok else { return }
            mini.apps.forEach { StubApps.remove($0, in: mini) }
            self.vms.removeAll { $0.id == mini.id }
            self.inGuest.remove(mini.id)
            self.exits[mini.id] = nil
            self.save()
            await self.apply()
        }
    }

    var ptySocket: URL { root.appendingPathComponent("pty.sock") }

    /// `~/V2Mac Sandbox/<VM>/Shared` (plan "Files"); kept when a mini VM is deleted, it holds the user's
    /// files. Two mini VMs never share one: a name another mini VM already uses gets the id added.
    func sharedFolder(_ mini: MiniVM) -> URL {
        func safe(_ m: MiniVM) -> String {
            let name = m.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            return name.isEmpty || name.hasPrefix(".") ? m.id : name
        }
        let clash = vms.contains { $0.id != mini.id && safe($0).lowercased() == safe(mini).lowercased() }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("V2Mac Sandbox/\(clash ? "\(safe(mini)) \(mini.id)" : safe(mini))/Shared", isDirectory: true)
    }

    /// Layers V2Mac downloaded, seen read-only in the VM as `/exchange/_cache` for `podman load`.
    var layerCache: URL { root.appendingPathComponent("cache", isDirectory: true) }

    private func updateShares() {
        try? FileManager.default.createDirectory(at: layerCache, withIntermediateDirectories: true)
        var shares: [String: URL] = ["_cache": layerCache]
        for mini in vms {
            let folder = sharedFolder(mini)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            shares[mini.id] = folder
        }
        vm.shares = shares
    }

    func setClipboard(_ mini: MiniVM, pasteIn: Bool? = nil, copyOut: Bool? = nil) {
        update(mini.id) { vm in
            if let pasteIn { vm.pasteIn = pasteIn }
            if let copyOut { vm.copyOut = copyOut }
        }
    }

    /// Installs (or updates) an app in a mini VM with the approved permissions and makes its Mac app.
    func install(_ manifest: PluginManifest, granted: [String], in mini: MiniVM) throws {
        guard let current = vms.first(where: { $0.id == mini.id }) else { return }
        let app = InstalledApp(manifest, granted: granted)
        try StubApps.make(app, in: current, socket: ptySocket)
        update(mini.id) { vm in vm.apps.removeAll { $0.id == app.id }; vm.apps.append(app) }
    }

    /// A store plugin (plan §7 "Install"): each layer through V2Mac (hash-checked there, cached by hash,
    /// so an update fetches only changed ones), loaded into podman in the VM; the app runs from its image.
    func install(store manifest: PluginManifest, granted: [String], in mini: MiniVM, download: @escaping (PluginManifest.Layer) async -> URL?) async throws {
        var image: String?
        for layer in manifest.layers ?? [] {
            guard await download(layer) != nil else { throw PluginManifest.Invalid("A layer of \(manifest.name) could not be downloaded or did not match the store.") }
            let loaded = await enqueueResult { await self.run(["load", layer.sha256]) }.value
            guard loaded.ok, let id = loaded.output.split(separator: "\n").last.map(String.init), AgentMessage.isWord(id)
            else { throw PluginManifest.Invalid("\(manifest.name) could not be loaded in the sandbox.") }
            image = id
        }
        guard let current = vms.first(where: { $0.id == mini.id }) else { return }
        var app = InstalledApp(manifest, granted: granted)
        app.unverified = false
        app.image = image
        app.source = manifest.source
        app.layers = manifest.layers ?? []
        try StubApps.make(app, in: current, socket: ptySocket)
        let old = current.apps.first { $0.id == app.id }?.image
        update(mini.id) { vm in vm.apps.removeAll { $0.id == app.id }; vm.apps.append(app) }
        if let old, old != image { enqueue { _ = await self.run(["rmi", old]) } }
    }

    func uninstall(_ app: InstalledApp, from mini: MiniVM) {
        StubApps.remove(app, in: mini)
        update(mini.id) { $0.apps.removeAll { $0.id == app.id } }
        // Still used by the same plugin in another mini VM: podman refuses, which is fine.
        if let image = app.image { enqueue { _ = await self.run(["rmi", image]) } }
    }

    func wipe(_ mini: MiniVM) {
        enqueue { _ = await self.run(["wipe", mini.id]) }
    }

    func setDisposable(_ mini: MiniVM, _ on: Bool) {
        update(mini.id) { $0.disposable = on }
        enqueue { _ = await self.run(["vm-add", String(mini.index), mini.id, on ? "1" : "0"]) }
    }

    /// Exit change without a restart: the outbound is swapped in the running sandbox core.
    func setExit(_ mini: MiniVM, _ server: String?) {
        update(mini.id) { $0.exit = server }
        enqueue { if let current = self.vms.first(where: { $0.id == mini.id }) { await self.swapExit(current) } }
    }

    private func update(_ id: String, _ change: (inout MiniVM) -> Void) {
        guard let i = vms.firstIndex(where: { $0.id == id }) else { return }
        change(&vms[i])
        save()
    }

    private func swapExit(_ mini: MiniVM) async {
        guard ready, let core else { return }
        var json: JSONValue?
        if let exit = mini.exit { json = await outbound(for: exit) }
        do {
            try await core.replaceOutbound(tag: mini.tag, with: SandboxConfig.exitOutbound(json, tag: mini.tag), apiPort: apiPort)
        } catch {
            log("exit swap failed, restarting the sandbox core: \(error.localizedDescription)")
            return await apply()
        }
        await checkExit(mini)
    }

    // MARK: Exit check (plan §4: "Exit down")

    private func checkExits() async {
        for mini in vms { await checkExit(mini) }
    }

    private func checkRoute(_ mini: MiniVM) -> FetchRoute? {
        ports[mini.id].map { .proxy(host: "127.0.0.1", port: $0.check, username: SandboxConfig.checkUser, password: checkPassword) }
    }

    private func checkExit(_ mini: MiniVM) async {
        guard mini.exit != nil, let route = checkRoute(mini) else { exits[mini.id] = mini.exit == nil ? ExitStatus.none : .unknown; return }
        let before = exits[mini.id]
        if let info = await ExitLookup.lookup(route: route) {
            exits[mini.id] = .ok([info.countryCode.map(Self.flag), info.place() ?? info.ip].compactMap { $0 }.joined(separator: " "))
        } else {
            exits[mini.id] = .down
            // One notice per outage, never a switch on its own (plan "Exit").
            if before != .down {
                let server = servers.first { $0.id == mini.exit }?.name ?? "its server"
                notice("\(mini.name) can't reach the internet through \(server). Its apps are blocked until it works again or you pick another server.")
            }
        }
    }

    static func flag(_ code: String) -> String {
        String(code.uppercased().unicodeScalars.compactMap { Unicode.Scalar(127397 + $0.value) }.map(Character.init))
    }

    // MARK: Leak probes (plan M2.6, §9)

    /// Two probe mini VMs on the active server: in-VM probes from one against the other, the exit
    /// seen by the host compared with the pod's, then a live exit swap. Returns the report.
    func probe() async -> String {
        report = []
        await enqueue {
            // Queued before the boot's own setup when the probe started the VM.
            if !self.ready { await self.apply() }
            guard self.ready else { return self.report.append("FAIL setup the gateway is not ready") }
            guard let exit = self.activeServer ?? self.servers.first?.id else { return self.report.append("FAIL setup V2Mac has no share-link server") }
            guard let a = MiniVM.new(name: "Probe A", exit: exit, taken: self.vms),
                  let b = MiniVM.new(name: "Probe B", exit: exit, taken: self.vms + [a]) else { return self.report.append("FAIL setup no free index") }
            self.report.append("INFO exit server \(self.servers.first { $0.id == exit }?.name ?? exit)")
            self.vms += [a, b]
            await self.apply()
            var hostIP: String?
            if let route = self.checkRoute(a) { hostIP = await ExitLookup.lookup(route: route)?.ip }
            let out = await self.run(["probe", String(a.index), a.id, String(b.index), b.id]).output
            self.report += out.split(separator: "\n").map(String.init)
            let podIP = self.report.first { $0.hasPrefix("PASS exit ") }.map { String($0.dropFirst(10)) }
            self.report.append(podIP != nil && podIP == hostIP ? "PASS exit-matches-host \(hostIP!)" : "FAIL exit-matches-host pod \(podIP ?? "-") host \(hostIP ?? "-")")
            // Live swap: to another server and back, same pods, no restart of the cores or pods.
            if let other = self.servers.first(where: { $0.id != exit }) {
                let after = await self.swapAndProbe(a, to: other.id, b)
                let back = await self.swapAndProbe(a, to: exit, b)
                let swapped = after != podIP && back == podIP && podIP != nil
                self.report.append("\(swapped ? "PASS" : "FAIL") swap \(podIP ?? "-") → \(after ?? "blocked") (\(other.name)) → \(back ?? "blocked")")
            } else {
                self.report.append("SKIP swap only one server")
            }
            for mini in [a, b] {
                _ = await self.run(["vm-del", String(mini.index), mini.id])
                self.vms.removeAll { $0.id == mini.id }
                self.inGuest.remove(mini.id)
            }
            self.save()
            await self.apply()
        }.value
        return report.joined(separator: "\n")
    }

    /// The pod's exit IP after a live exit swap, nil when nothing gets through.
    private func swapAndProbe(_ mini: MiniVM, to server: String, _ other: MiniVM) async -> String? {
        update(mini.id) { $0.exit = server }
        await swapExit(vms.first { $0.id == mini.id }!)
        return await run(["probe", String(mini.index), mini.id, String(other.index), other.id]).output
            .split(separator: "\n").first { $0.hasPrefix("PASS exit ") }.map { String($0.dropFirst(10)) }
    }

    func stop() async {
        watch?.cancel()
        await core?.stop()
    }
}
