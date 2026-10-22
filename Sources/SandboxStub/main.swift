// The generated per-app stub (plan §5). Its name, bundle id and icon come from its own Info.plist;
// a pty app's stub opens its launch.command in the user's Terminal and quits.
import AppKit

if let command = Bundle.main.url(forResource: "launch", withExtension: "command") {
    NSWorkspace.shared.open(command)
}
