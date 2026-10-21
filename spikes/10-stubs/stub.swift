// Spike 0.10: the tiny stub. Its identity (name, bundle id, icon) comes only from its own Info.plist.
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "?"
let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 360, height: 120), styleMask: [.titled, .closable], backing: .buffered, defer: false)
w.title = name
w.contentView = NSTextField(labelWithString: "  \(Bundle.main.bundleIdentifier ?? "?")")
w.makeKeyAndOrderFront(nil)
print("[stub] \(name) pid \(getpid()) bundle \(Bundle.main.bundleIdentifier ?? "?")")
app.activate()
app.run()
