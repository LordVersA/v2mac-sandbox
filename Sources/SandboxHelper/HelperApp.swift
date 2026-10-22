import AppKit
import SwiftUI
import V2MacCore

/// Runs the helper: the link to V2Mac, the VM and the Sandbox window.
@MainActor public final class HelperApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let link = AppLink()
    private let vm: SandboxVM
    private let model = WindowModel()
    private var ramCapMB = SandboxFiles.defaultRAMCapMB(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    private var window: NSWindow?

    public override init() {
        // The helper lives in <data>/sandbox/V2Mac Sandbox.app; the VM's files go next to it.
        vm = SandboxVM(root: Bundle.main.bundleURL.deletingLastPathComponent())
        super.init()
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
            self?.link.send(.vmState(state.rawValue))
        }
        link.start(onMessage: { [weak self] in self?.handle($0) }, onClose: { [weak self] in self?.quit() })
        link.send(.hello(version: SandboxLink.version))
    }

    private func handle(_ message: SandboxLink.ToHelper) {
        switch message {
        case .hello(let version, let ram):
            guard version == SandboxLink.version else { log("V2Mac speaks link version \(version)"); return quit() }
            ramCapMB = ram
        case .settings(let ram): ramCapMB = ram // used at the next boot
        case .openWindow: showWindow()
        case .quitRequest: link.send(.quitReply(appsOpen: false)) // no sandbox apps before M2
        case .quit: quit()
        case .servers, .outbound, .downloaded: break // M2
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
            await vm.stop()
            exit(0)
        }
    }
}

@MainActor @Observable final class WindowModel {
    var state = SandboxVM.State.stopped
    var start: () -> Void = {}
    var stop: () -> Void = {}
}

/// shortcut: a status page until M2 brings the mini VM list.
struct SandboxWindow: View {
    let model: WindowModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "shield.lefthalf.filled").font(.system(size: 48)).foregroundStyle(.tint)
            Text(title).font(.title2)
            switch model.state {
            case .stopped: Button("Start") { model.start() }
            case .running: Button("Stop") { model.stop() }
            case .booting, .stopping: ProgressView().controlSize(.small)
            }
        }
        .padding(40)
        .frame(minWidth: 360, minHeight: 240)
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
