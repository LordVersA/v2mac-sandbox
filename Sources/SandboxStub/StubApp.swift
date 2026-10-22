import AppKit
import RFB

/// A window app's Mac side: one window, its menu, and the session through the helper's socket.
@MainActor final class StubApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let socket: String, vm: String, app: String, name: String
    private var window: NSWindow?
    private var view: RFBView?
    private var fd: Int32 = -1

    init(socket: String, vm: String, app: String, name: String) {
        self.socket = socket; self.vm = vm; self.app = app; self.name = name
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = menu()
        let screen = NSScreen.main
        let scale = Int(screen?.backingScaleFactor ?? 2) >= 2 ? 2 : 1
        let points = NSSize(width: 1100, height: 720)
        fd = Self.connect(socket)
        guard fd >= 0 else { return fail(String(localized: "V2Mac Sandbox is not running. Open the Sandbox in V2Mac, then open this app again.")) }
        let line = "gui \(vm) \(app) \(Int(points.width) * scale) \(Int(points.height) * scale) \(scale)\n"
        _ = Array(line.utf8).withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        let socketFD = fd
        Thread.detachNewThread { [weak self] in
            // Header: "ok <copy to Mac 0|1> <title capsule>", or the helper's reason for saying no.
            let header = Self.readLine(socketFD) ?? ""
            DispatchQueue.main.async { self?.start(header: header, points: points, scale: scale) }
        }
    }

    private func start(header: String, points: NSSize, scale: Int) {
        let words = header.split(separator: " ", maxSplits: 2).map(String.init)
        guard words.first == "ok", words.count == 3 else {
            return fail(header.replacingOccurrences(of: "v2mac-pty: ", with: "").isEmpty ? String(localized: "The sandbox did not answer.") : header)
        }
        let fd = fd
        let client = RFBClient(read: { Darwin.read(fd, $0.baseAddress, $0.count) },
                               write: { bytes in _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } })
        let view = RFBView(client: client, copyOut: words[1] == "1")
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: points), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = name
        window.subtitle = words[2]
        window.contentView = view
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate()
        self.window = window
        self.view = view
        Thread.detachNewThread {
            do {
                try client.handshake()
                try client.run()
            } catch {
                print("[stub] session ended: \(error)")
                DispatchQueue.main.async { NSApp.terminate(nil) } // the app or the sandbox ended the session
            }
        }
    }

    private func fail(_ text: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "\(name) can't open")
        alert.informativeText = text
        alert.runModal()
        NSApp.terminate(nil)
    }

    func windowDidEndLiveResize(_ notification: Notification) { view?.sendSize() }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func menu() -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "Hide \(name)"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: String(localized: "Quit \(name)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(RFBView.paste(_:)), keyEquivalent: "v")
        let window = NSMenu(title: String(localized: "Window"))
        window.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        for menu in [appMenu, edit, window] {
            let item = NSMenuItem()
            item.submenu = menu
            main.addItem(item)
        }
        return main
    }

    nonisolated static func connect(_ path: String) -> Int32 {
        let s = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { p in for (i, ch) in path.utf8.prefix(p.count - 1).enumerated() { p[i] = ch } }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
        if !ok { close(s); return -1 }
        return s
    }

    nonisolated static func readLine(_ fd: Int32) -> String? {
        var bytes: [UInt8] = []
        var b: UInt8 = 0
        while bytes.count < 512, Darwin.read(fd, &b, 1) == 1 {
            if b == 0x0a { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(b)
        }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }
}
