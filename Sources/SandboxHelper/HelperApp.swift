import AppKit
import SwiftUI
import V2MacCore

/// Runs the helper: the link to V2Mac, the VM and the Sandbox window.
@MainActor public final class HelperApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let link = AppLink()
    private let vm: SandboxVM
    private let gateway: Gateway
    private let model: WindowModel
    private var pty: PtyServer!
    private let store: StoreClient
    private let quarantine = QuarantineWatcher(folder: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("V2Mac Sandbox"))
    private var ramCapMB = SandboxFiles.defaultRAMCapMB(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    private var window: NSWindow?

    public override init() {
        // The helper lives in <data>/sandbox/V2Mac Sandbox.app; the VM's files go next to it.
        let root = Bundle.main.bundleURL.deletingLastPathComponent()
        vm = SandboxVM(root: root)
        gateway = Gateway(vm: vm, root: root)
        store = StoreClient(root: root)
        model = WindowModel(gateway: gateway, store: store)
        super.init()
        pty = PtyServer(vm: vm, gateway: gateway, store: store, root: root) { [unowned self] in vm.retain(ramCapMB: ramCapMB) }
    }

    public static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard AppLink.isPresent else {
            log("start V2Mac Sandbox from V2Mac")
            exit(2)
        }
        let app = NSApplication.shared
        let delegate = HelperApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        vm.onState = { [weak self] state in
            log("VM \(state.rawValue)")
            self?.model.state = state
            self?.gateway.vmStateChanged(state)
            self?.link.send(.vmState(state.rawValue))
        }
        gateway.requestOutbound = { [weak self] in self?.link.send(.outbound(id: $0)) }
        gateway.notice = { [weak self] in self?.link.send(.notice(kind: "sandboxExitDown", text: $0)) }
        store.fetch = { [weak self] url in await self?.link.request { .fetch(request: $0, url: url) } }
        model.download = { [weak self] layer in await self?.link.request { .download(request: $0, url: layer.url, sha256: layer.sha256) } }
        link.start(onMessage: { [weak self] in self?.handle($0) }, onClose: { [weak self] in self?.quit() })
        link.send(.hello(version: SandboxLink.version))
        pty.start()
        quarantine.start()
        sideloadHook()
        templateHook()
    }

    /// `V2MAC_SANDBOX_TEMPLATE=<template id>` with a local `V2MAC_SANDBOX_STORE` (dev testing): makes a
    /// mini VM from that store template with every permission its apps ask for, and logs the outcome.
    private func templateHook() {
        guard let id = ProcessInfo.processInfo.environment["V2MAC_SANDBOX_TEMPLATE"] else { return }
        vm.retain(ramCapMB: ramCapMB)
        Task {
            for _ in 0..<900 where !gateway.ready || gateway.servers.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            await store.refresh(force: true)
            guard let template = store.index?.templates.first(where: { $0.id == id }) else {
                vm.release()
                return log("template \(id): \(store.problem ?? "not in the index")")
            }
            guard !store.isExpired, let mini = gateway.add(name: template.name) else {
                vm.release()
                return log("template \(id): the index has expired, nothing installed")
            }
            for plugin in template.plugins.compactMap({ store.index?.plugin($0) }) {
                do {
                    try await gateway.install(store: plugin, granted: plugin.permissions ?? [], in: mini, download: model.download)
                    log("template \(id): installed \(plugin.id) \(plugin.version) into \(mini.name) (\(mini.id))")
                } catch {
                    log("template \(id): \(plugin.id) refused: \(error.localizedDescription)")
                }
            }
            vm.release()
        }
    }

    /// `V2MAC_SANDBOX_SIDELOAD=<plugin folder>` (dev testing): boots the VM, makes mini VM "Work" if
    /// missing and installs the plugin there with every permission it asks for.
    private func sideloadHook() {
        guard let folder = ProcessInfo.processInfo.environment["V2MAC_SANDBOX_SIDELOAD"] else { return }
        vm.retain(ramCapMB: ramCapMB)
        Task {
            @MainActor func work() -> MiniVM? { gateway.vms.first { $0.name == "Work" } }
            for _ in 0..<900 where !gateway.ready || gateway.servers.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            if work() == nil { gateway.add(name: "Work") }
            for _ in 0..<900 where work() == nil || !gateway.ready { try? await Task.sleep(for: .milliseconds(100)) }
            do {
                let manifest = try PluginManifest.load(folder: URL(fileURLWithPath: folder))
                try gateway.install(manifest, granted: manifest.permissions ?? [], in: work()!)
                log("sideloaded \(manifest.id) into Work: \(StubApps.url(InstalledApp(manifest, granted: []), in: work()!).path)")
            } catch {
                log("sideload failed: \(error.localizedDescription)")
            }
            vm.release()
        }
    }

    private func handle(_ message: SandboxLink.ToHelper) {
        switch message {
        case .hello(let version, let ram, let core):
            guard version == SandboxLink.version else { log("V2Mac speaks link version \(version)"); return quit() }
            ramCapMB = ram
            gateway.corePath = URL(fileURLWithPath: core)
        case .settings(let ram): ramCapMB = ram // used at the next boot
        case .openWindow: showWindow()
        case .quitRequest: link.send(.quitReply(appsOpen: pty.sessions > 0))
        case .quit: quit()
        case .servers(let list, let active): gateway.serversChanged(list, active: active)
        case .outbound(let id, let json): gateway.received(id: id, json: json)
        case .probe:
            vm.retain(ramCapMB: ramCapMB)
            Task {
                link.send(.probe(await gateway.probe()))
                vm.release()
            }
        case .downloaded(let request, let path): link.downloaded(request, path: path)
        }
    }

    private func showWindow() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SandboxWindow(model: model)))
            window.title = "V2Mac Sandbox"
            window.delegate = self
            window.isReleasedWhenClosed = false
            self.window = window
            model.stop = { [weak self] in Task { await self?.vm.stop() } }
            model.start = { [weak self] in guard let self else { return }; vm.boot(ramCapMB: ramCapMB) }
        }
        if window?.isVisible != true { vm.retain(ramCapMB: ramCapMB) }
        Task { await store.refresh() } // plan §7: when the window opens, at most daily
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    public func windowWillClose(_ notification: Notification) {
        vm.release()
        NSApp.setActivationPolicy(.accessory)
    }

    private func quit() {
        Task {
            await gateway.stop()
            await vm.stop()
            exit(0)
        }
    }
}

@MainActor @Observable final class WindowModel {
    var state = SandboxVM.State.stopped
    var start: () -> Void = {}
    var stop: () -> Void = {}
    @ObservationIgnored var download: (PluginManifest.Layer) async -> URL? = { _ in nil }
    let gateway: Gateway
    let store: StoreClient
    init(gateway: Gateway, store: StoreClient) { self.gateway = gateway; self.store = store }
}

/// The Sandbox window: the VM's state and the mini VMs with their exits (plan M2).
struct SandboxWindow: View {
    let model: WindowModel
    @State private var confirm: (title: String, action: () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "shield.lefthalf.filled").foregroundStyle(.tint)
                Text(title).font(.headline)
                Spacer()
                switch model.state {
                case .stopped: Button("Start") { model.start() }
                case .running:
                    Menu("Add Mini VM", systemImage: "plus") {
                        Button("Empty") { model.gateway.add() }
                        if let templates = model.store.index?.templates, !templates.isEmpty {
                            Section("Templates") { ForEach(templates, id: \.id) { t in Button(t.name) { addFromTemplate(t) } } }
                        }
                        if !model.gateway.vms.isEmpty {
                            Section("Clone") { ForEach(model.gateway.vms) { vm in Button("\(vm.name) (apps and data)") { model.gateway.add(cloning: vm) } } }
                        }
                    }
                    .fixedSize()
                    .disabled(!model.gateway.ready)
                    Button("Stop") { model.stop() }
                case .booting, .stopping: ProgressView().controlSize(.small)
                }
            }
            if model.gateway.vms.isEmpty {
                ContentUnavailableView("No mini VMs", systemImage: "square.stack.3d.up",
                                       description: Text("Each mini VM has its own exit and its own data."))
            } else {
                List(model.gateway.vms) { vm in row(vm) }
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 320)
        .confirmationDialog(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Continue", role: .destructive) { confirm?.action() }
        }
    }

    private func row(_ vm: MiniVM) -> some View {
        let gateway = model.gateway
        return HStack {
            Text(vm.name)
            if vm.disposable { Image(systemName: "flame").help("Disposable: data is gone when the sandbox stops") }
            Spacer()
            capsule(gateway.exits[vm.id] ?? .unknown)
            Picker("Exit", selection: Binding(get: { vm.exit }, set: { gateway.setExit(vm, $0) })) {
                Text("No exit (blocked)").tag(String?.none)
                ForEach(gateway.servers, id: \.id) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden()
            .frame(width: 180)
            ForEach(vm.apps) { app in
                let revoked = model.store.index?.revocation(of: app)
                let newer = model.store.index?.plugin(app.id).flatMap { $0.version != app.version && !app.unverified ? $0 : nil }
                Button(app.name, systemImage: revoked != nil ? "exclamationmark.octagon.fill" : app.display == "gui" ? "macwindow" : "terminal") {
                    NSWorkspace.shared.open(StubApps.url(app, in: vm))
                }
                .help(revoked.map { "Withdrawn from the store: \($0.reason)" } ?? (app.unverified ? "Unverified: sideloaded, not from the V2Mac store" : app.name))
                .contextMenu {
                    Button("Verify Installation…") { verify(app, in: vm) }
                    if let newer { Button("Update to \(newer.version)") { installFromStore(newer, into: vm, keeping: app.granted) } }
                    Button("Remove \(app.name)", role: .destructive) { gateway.uninstall(app, from: vm) }
                }
            }
            Menu {
                Menu("Add App") {
                    ForEach(model.store.index?.plugins ?? [], id: \.id) { plugin in
                        Button("\(plugin.name) \(plugin.version)") { installFromStore(plugin, into: vm) }
                    }
                    .disabled(model.store.isExpired)
                    if let problem = model.store.problem { Text(problem) }
                    Divider()
                    Button("From Folder (Unverified)…") { addApp(to: vm) }
                }
                Toggle("Paste from Mac", isOn: Binding(get: { vm.pasteIn }, set: { gateway.setClipboard(vm, pasteIn: $0) }))
                Toggle("Copy to Mac", isOn: Binding(get: { vm.copyOut }, set: { gateway.setClipboard(vm, copyOut: $0) }))
                Button("Show Shared Folder") { NSWorkspace.shared.open(gateway.sharedFolder(vm)) }
                Divider()
                Toggle("Disposable", isOn: Binding(get: { vm.disposable }, set: { gateway.setDisposable(vm, $0) }))
                Button("Clone") { gateway.add(cloning: vm) }
                Button("Wipe Data…") { confirm = ("Wipe all data of \(vm.name)?", { gateway.wipe(vm) }) }
                Button("Delete…", role: .destructive) { confirm = ("Delete \(vm.name) and all its data?", { gateway.delete(vm) }) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .disabled(!gateway.ready)
    }

    /// Dev sideload (plan "Publishing"): a plugin folder, its permissions approved by the user.
    private func addApp(to vm: MiniVM) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a plugin folder (with plugin.json)"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let manifest = try PluginManifest.load(folder: folder)
            guard let granted = Self.approve(manifest.name, asks: manifest.permissions ?? [], into: vm.name, note: "It is not from the V2Mac store (Unverified).") else { return }
            try model.gateway.install(manifest, granted: granted, in: vm)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Asks the user to approve an app's permissions (plan §6); nil when cancelled.
    static func approve(_ name: String, asks: [String], into vm: String, note: String? = nil) -> [String]? {
        let alert = NSAlert()
        alert.messageText = "Install \(name) in \(vm)?"
        let lines = asks.map { "• " + permissionText[$0, default: $0] }
        alert.informativeText = ([note].compactMap { $0 } + (asks.isEmpty ? [] : ["It asks to:"] + lines)).joined(separator: "\n")
        alert.addButton(withTitle: asks.isEmpty ? "Install" : "Allow and Install")
        if !asks.isEmpty { alert.addButton(withTitle: "Install Without These") }
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return asks
        case .alertSecondButtonReturn where !asks.isEmpty: return []
        default: return nil
        }
    }

    /// Install or update from the signed index; an update keeps earlier approvals unless it asks for more.
    private func installFromStore(_ plugin: PluginManifest, into vm: MiniVM, keeping granted: [String]? = nil) {
        guard !model.store.isExpired else { return }
        let asks = plugin.permissions ?? []
        let approved: [String]? = if let granted, Set(asks).isSubset(of: granted) { asks.filter(granted.contains) } else { Self.approve(plugin.name, asks: asks, into: vm.name) }
        guard let approved else { return }
        Task {
            do { try await model.gateway.install(store: plugin, granted: approved, in: vm, download: model.download) }
            catch { NSAlert(error: error).runModal() }
        }
    }

    /// A new mini VM named after the template with its apps (plan "Add": Template); one approval for all.
    private func addFromTemplate(_ template: StoreIndex.Template) {
        let plugins = template.plugins.compactMap { model.store.index?.plugin($0) }
        let asks = Array(Set(plugins.flatMap { $0.permissions ?? [] })).sorted()
        guard !model.store.isExpired, let granted = Self.approve(plugins.map(\.name).joined(separator: ", "), asks: asks, into: template.name),
              let vm = model.gateway.add(name: template.name) else { return }
        Task {
            for plugin in plugins {
                do { try await model.gateway.install(store: plugin, granted: (plugin.permissions ?? []).filter(granted.contains), in: vm, download: model.download) }
                catch { NSAlert(error: error).runModal() }
            }
        }
    }

    /// Verify Installation (plan §7): where it came from and whether its layers are unchanged since
    /// published. "Verified" means unchanged, not safe.
    private func verify(_ app: InstalledApp, in vm: MiniVM) {
        var lines = ["Version \(app.version)", "Permissions: \(app.granted.isEmpty ? "none" : app.granted.joined(separator: ", "))"]
        if app.unverified {
            lines.append("Unverified: sideloaded from a folder, not from the V2Mac store.")
        } else {
            if let source = app.source { lines.append("Source: \(source.repo) at \(source.commit)") }
            let listed = model.store.index?.plugin(app.id)
            lines.append(listed?.version == app.version && listed?.layers == app.layers ? "Listed in the signed store index." : "Not in the current signed store index as installed.")
            if let revoked = model.store.index?.revocation(of: app) { lines.append("Withdrawn: \(revoked.reason)") }
            let intact = app.layers.allSatisfy { (try? SandboxFiles.sha256(of: model.gateway.layerCache.appendingPathComponent($0.sha256))) == $0.sha256 }
            lines.append(intact ? "Layers re-hashed: unchanged since published." : "Layers re-hashed: CHANGED or missing.")
        }
        let alert = NSAlert()
        alert.messageText = "\(app.name) in \(vm.name)"
        alert.informativeText = lines.joined(separator: "\n")
        alert.runModal()
    }

    static let permissionText = [
        "ssh-agent": "Use the SSH keys in your Mac's ssh-agent while it is open",
        "clipboard": "Use the clipboard",
        "shared": "Read and write this mini VM's Shared folder",
    ]

    @ViewBuilder private func capsule(_ status: Gateway.ExitStatus) -> some View {
        switch status {
        case .ok(let place): Label(place, systemImage: "shield.fill").foregroundStyle(.green)
        case .down: Label("Not connected", systemImage: "exclamationmark.shield.fill").foregroundStyle(.red)
        case .none: Label("Blocked", systemImage: "nosign").foregroundStyle(.secondary)
        case .unknown: ProgressView().controlSize(.mini)
        }
    }

    private var title: String {
        switch model.state {
        case .stopped: "Sandbox is stopped"
        case .booting: "Starting the sandbox…"
        case .running: "Sandbox is running"
        case .stopping: "Stopping the sandbox…"
        }
    }
}
