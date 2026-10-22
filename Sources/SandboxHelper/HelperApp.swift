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
            let host = NSHostingController(rootView: SandboxWindow(model: model))
            host.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentViewController: host)
            window.styleMask.insert(.fullSizeContentView)
            window.setContentSize(NSSize(width: 820, height: 560))
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
