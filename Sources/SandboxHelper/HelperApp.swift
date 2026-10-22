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
    private let quarantine = QuarantineWatcher(folder: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("V2Mac Sandbox"))
    private var ramCapMB = SandboxFiles.defaultRAMCapMB(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    private var window: NSWindow?

    public override init() {
        // The helper lives in <data>/sandbox/V2Mac Sandbox.app; the VM's files go next to it.
        let root = Bundle.main.bundleURL.deletingLastPathComponent()
        vm = SandboxVM(root: root)
        gateway = Gateway(vm: vm, root: root)
        model = WindowModel(gateway: gateway)
        super.init()
        pty = PtyServer(vm: vm, gateway: gateway, root: root) { [unowned self] in vm.retain(ramCapMB: ramCapMB) }
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
        link.start(onMessage: { [weak self] in self?.handle($0) }, onClose: { [weak self] in self?.quit() })
        link.send(.hello(version: SandboxLink.version))
        pty.start()
        quarantine.start()
        sideloadHook()
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
        case .downloaded: break // M5
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
    let gateway: Gateway
    init(gateway: Gateway) { self.gateway = gateway }
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
                    Button("Add Mini VM", systemImage: "plus") { model.gateway.add() }.disabled(!model.gateway.ready)
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
                Button(app.name, systemImage: app.display == "gui" ? "macwindow" : "terminal") { NSWorkspace.shared.open(StubApps.url(app, in: vm)) }
                    .help(app.unverified ? "Unverified: sideloaded, not from the V2Mac store" : app.name)
                    .contextMenu { Button("Remove \(app.name)", role: .destructive) { gateway.uninstall(app, from: vm) } }
            }
            Menu {
                Button("Add App from Folder…") { addApp(to: vm) }
                Toggle("Paste from Mac", isOn: Binding(get: { vm.pasteIn }, set: { gateway.setClipboard(vm, pasteIn: $0) }))
                Toggle("Copy to Mac", isOn: Binding(get: { vm.copyOut }, set: { gateway.setClipboard(vm, copyOut: $0) }))
                Button("Show Shared Folder") { NSWorkspace.shared.open(Gateway.sharedFolder(vm)) }
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
        let alert = NSAlert()
        do {
            let manifest = try PluginManifest.load(folder: folder)
            let asks = manifest.permissions ?? []
            alert.messageText = "Install \(manifest.name) in \(vm.name)?"
            let lines = asks.map { "• " + Self.permissionText[$0, default: $0] }
            alert.informativeText = (["It is not from the V2Mac store (Unverified)."] + (asks.isEmpty ? [] : ["It asks to:"] + lines)).joined(separator: "\n")
            alert.addButton(withTitle: asks.isEmpty ? "Install" : "Allow and Install")
            if !asks.isEmpty { alert.addButton(withTitle: "Install Without These") }
            alert.addButton(withTitle: "Cancel")
            let answer = alert.runModal()
            guard answer != .alertThirdButtonReturn, asks.isEmpty ? answer == .alertFirstButtonReturn : true else { return }
            try model.gateway.install(manifest, granted: answer == .alertFirstButtonReturn ? asks : [], in: vm)
        } catch {
            NSAlert(error: error).runModal()
        }
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
