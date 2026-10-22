// The VM agent (plan §3): the only process in the VM that owns vsock. It talks to the helper alone,
// on port 1024, with the fixed `AgentMessage` set.
#if canImport(Musl)
import AgentProtocol
import Musl

setvbuf(stdout, nil, _IOLBF, 0)

// Every fd here is close-on-exec: a vsock fd inherited by the gateway script would reach
// containers past the seccomp rule, and an inherited pipe end keeps `run` waiting forever.
func listenVsock(_ port: UInt32) -> Int32 {
    let s = socket(40 /* AF_VSOCK */, Int32(SOCK_STREAM) | Int32(SOCK_CLOEXEC), 0)
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

/// Runs the gateway script and waits for it; stdout and stderr together, cut to fit one frame.
func runScript(_ words: [String]) -> AgentMessage {
    var fds: [Int32] = [0, 0]
    guard pipe2(&fds, O_CLOEXEC) == 0 else { return .result(status: -1, output: "pipe failed") }
    var actions = posix_spawn_file_actions_t()
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
    posix_spawn_file_actions_adddup2(&actions, fds[1], 2)
    posix_spawn_file_actions_addclose(&actions, fds[0])
    var pid: pid_t = 0
    let argv = ["/bin/sh", "/usr/local/lib/v2mac/sandbox.sh"] + words
    var cargs = argv.map { strdup($0) } + [nil]
    let spawned = posix_spawn(&pid, argv[0], &actions, nil, &cargs, nil)
    close(fds[1])
    var output: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 4096)
    while case let n = read(fds[0], &buf, buf.count), n > 0 {
        if output.count < AgentMessage.maxFrame - 64 { output += buf[0..<min(n, AgentMessage.maxFrame - 64 - output.count)] }
    }
    close(fds[0])
    guard spawned == 0 else { return .result(status: -1, output: "could not run the gateway script") }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    return .result(status: Int((status >> 8) & 0xff), output: String(decoding: output, as: UTF8.self))
}

func put(_ name: String, _ body: String) -> Bool {
    mkdir("/run/v2mac", 0o700)
    let fd = open("/run/v2mac/\(name)", O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    return writeAll(fd, Array(body.utf8))
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
            case .put(let name, let body):
                writeAll(c, (put(name, body) ? AgentMessage.ok : .result(status: -1, output: "could not write \(name)")).frame)
            case .run(let words):
                writeAll(c, runScript(words).frame)
            case .hello, .ok, .result:
                return // only the agent sends these
            }
        }
    }
}

let s = listenVsock(AgentMessage.port)
print("agent: listening on vsock \(AgentMessage.port)")
while true {
    let c = accept4(s, nil, nil, Int32(SOCK_CLOEXEC))
    if c >= 0 { serve(c) }
}
#endif
