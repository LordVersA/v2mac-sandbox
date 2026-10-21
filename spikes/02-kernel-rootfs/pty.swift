// Spike 0.11: v2mac-pty, run inside Terminal.app. Raw mode, keyboard and resize as frames to the helper.
import Foundation
setvbuf(stdout, nil, _IONBF, 0)
let s = socket(AF_UNIX, SOCK_STREAM, 0)
var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutableBytes(of: &addr.sun_path) { p in for (i, ch) in "/tmp/v2mac-pty-spike.sock".utf8.enumerated() { p[i] = ch } }
guard withUnsafePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }) == 0 else { print("v2mac-pty: helper not running"); exit(1) }
var saved = termios(); tcgetattr(0, &saved)
var raw = saved; cfmakeraw(&raw); tcsetattr(0, TCSANOW, &raw)
atexit { var t = saved; tcsetattr(0, TCSANOW, &t) }
func send(_ b: [UInt8]) { _ = b.withUnsafeBytes { write(s, $0.baseAddress, b.count) } }
func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
func sendSize() { var ws = winsize(); ioctl(0, TIOCGWINSZ, &ws); send([1] + be16(Int(ws.ws_row)) + be16(Int(ws.ws_col))) }
sendSize()
let winch = DispatchSource.makeSignalSource(signal: SIGWINCH); signal(SIGWINCH, SIG_IGN)
winch.setEventHandler(handler: sendSize); winch.resume()
Thread.detachNewThread {
    var buf = [UInt8](repeating: 0, count: 4096)
    while case let n = read(0, &buf, buf.count), n > 0 { send([0] + be16(n) + buf[0..<n]) }
}
Thread.detachNewThread {
    var buf = [UInt8](repeating: 0, count: 65536)
    while case let n = read(s, &buf, buf.count), n > 0 { write(1, buf, n) }
    exit(0)
}
dispatchMain()
