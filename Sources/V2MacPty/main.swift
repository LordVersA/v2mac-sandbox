// v2mac-pty <socket> <vm id> <app id> <title>: runs in Terminal for a pty app (plan §5). Raw mode;
// keyboard and resizes go to the helper as `PtyInput` frames, the app's output comes back as is.
import AgentProtocol
import Foundation

let args = CommandLine.arguments
guard args.count == 5 else { print("usage: v2mac-pty <socket> <vm> <app> <title>"); exit(2) }
let s = socket(AF_UNIX, SOCK_STREAM, 0)
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutableBytes(of: &addr.sun_path) { p in for (i, ch) in args[1].utf8.prefix(p.count - 1).enumerated() { p[i] = ch } }
guard withUnsafePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }) == 0 else {
    print("V2Mac Sandbox is not running. Open the Sandbox in V2Mac, then open this app again.")
    exit(1)
}
func send(_ bytes: [UInt8]) { _ = bytes.withUnsafeBytes { write(s, $0.baseAddress, $0.count) } }
send(Array("\(args[2]) \(args[3])\n".utf8))
print("\u{1b}]0;🛡 \(args[4]) · V2Mac Protected\u{7}", terminator: "")
fflush(stdout)

var saved = termios()
tcgetattr(0, &saved)
var raw = saved
cfmakeraw(&raw)
tcsetattr(0, TCSANOW, &raw)
nonisolated(unsafe) let restore = saved
atexit { var t = restore; tcsetattr(0, TCSANOW, &t) }

func sendSize() {
    var size = winsize()
    ioctl(0, TIOCGWINSZ, &size)
    send(PtyInput.resize(rows: Int(size.ws_row), cols: Int(size.ws_col)).frame)
}
sendSize()
signal(SIGWINCH, SIG_IGN)
let winch = DispatchSource.makeSignalSource(signal: SIGWINCH)
winch.setEventHandler(handler: sendSize)
winch.resume()
Thread.detachNewThread {
    var buf = [UInt8](repeating: 0, count: 4096)
    while case let n = read(0, &buf, buf.count), n > 0 { send(PtyInput.data(Array(buf[0..<n])).frame) }
    shutdown(s, SHUT_WR)
}
Thread.detachNewThread {
    var buf = [UInt8](repeating: 0, count: 65536)
    while case let n = read(s, &buf, buf.count), n > 0 { _ = buf.withUnsafeBytes { write(1, $0.baseAddress, n) } }
    exit(0)
}
dispatchMain()
