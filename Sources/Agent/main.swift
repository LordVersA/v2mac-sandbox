// The VM agent (plan §3): the only process in the VM that owns vsock. It talks to the helper alone,
// on port 1024, with the fixed `AgentMessage` set.
#if canImport(Musl)
import AgentProtocol
import Musl

setvbuf(stdout, nil, _IOLBF, 0)

func listenVsock(_ port: UInt32) -> Int32 {
    let s = socket(40 /* AF_VSOCK */, Int32(SOCK_STREAM), 0)
    // sockaddr_vm: family u16, reserved u16, port u32, cid u32, then zeros
    var addr = [UInt8](repeating: 0, count: 16)
    addr.withUnsafeMutableBytes { b in
        b.storeBytes(of: UInt16(40), toByteOffset: 0, as: UInt16.self)
        b.storeBytes(of: port, toByteOffset: 4, as: UInt32.self)
        b.storeBytes(of: UInt32.max, toByteOffset: 8, as: UInt32.self) // VMADDR_CID_ANY
    }
    let bound = addr.withUnsafeBytes { bind(s, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), 16) }
    guard s >= 0, bound == 0, listen(s, 4) == 0 else { print("agent: vsock \(port) listen failed errno \(errno)"); exit(1) }
    return s
}

@discardableResult func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var off = 0
    while off < bytes.count {
        let w = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if w <= 0 { return false }
        off += w
    }
    return true
}

func spawn(_ argv: [String]) {
    var pid: pid_t = 0
    var cargs = argv.map { strdup($0) } + [nil]
    if posix_spawnp(&pid, argv[0], nil, nil, &cargs, nil) != 0 { print("agent: could not run \(argv[0])") }
}

func serve(_ c: Int32) {
    defer { close(c) }
    guard writeAll(c, AgentMessage.hello(version: AgentMessage.version).frame) else { return }
    var reader = AgentMessage.Reader()
    var buf = [UInt8](repeating: 0, count: 4096)
    while case let n = read(c, &buf, buf.count), n > 0 {
        guard let messages = try? reader.feed(buf[0..<n]) else { print("agent: bad frame, closing"); return }
        for message in messages {
            switch message {
            case .shutdown:
                writeAll(c, AgentMessage.ok.frame)
                spawn(["systemctl", "poweroff"])
            case .hello, .ok:
                return // only the agent sends these
            }
        }
    }
}

signal(SIGCHLD, SIG_IGN)
let s = listenVsock(AgentMessage.port)
print("agent: listening on vsock \(AgentMessage.port)")
while true {
    let c = accept(s, nil, nil)
    if c >= 0 { serve(c) }
}
#endif
