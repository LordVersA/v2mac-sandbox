// The generated per-app stub (plan §5). Its name, bundle id and icon come from its own Info.plist.
// A pty app's stub opens its launch.command in the user's Terminal and quits; a window app's stub is
// the app's Mac window: it asks the helper for the app and draws its RFB stream.
import AppKit

let info = Bundle.main.infoDictionary ?? [:]
if info["V2MacDisplay"] as? String != "gui" {
    if let command = Bundle.main.url(forResource: "launch", withExtension: "command") { NSWorkspace.shared.open(command) }
    exit(0)
}
let app = NSApplication.shared
let delegate = StubApp(socket: info["V2MacSocket"] as? String ?? "", vm: info["V2MacVM"] as? String ?? "",
                       app: info["V2MacApp"] as? String ?? "", name: info["CFBundleName"] as? String ?? "App")
app.delegate = delegate
app.setActivationPolicy(.regular)
withExtendedLifetime(delegate) { app.run() }
