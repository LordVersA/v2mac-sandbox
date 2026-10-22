// Spike 0.3: static agent. Listens on vsock 1024; per connection replies with the interfaces seen
// through a raw NETLINK_ROUTE dump and the output of `podman --version`, then closes.
import Musl

func netlinkLinks() -> [String] {
    let fd = socket(AF_NETLINK, Int32(SOCK_RAW), 0 /* NETLINK_ROUTE */)
    guard fd >= 0 else { return ["netlink socket failed"] }
    defer { close(fd) }
    // nlmsghdr(16) + ifinfomsg(16): RTM_GETLINK = 18, NLM_F_REQUEST|NLM_F_DUMP = 0x301
    var req = [UInt8](repeating: 0, count: 32)
    req.withUnsafeMutableBytes { b in
        b.storeBytes(of: UInt32(32), toByteOffset: 0, as: UInt32.self)
        b.storeBytes(of: UInt16(18), toByteOffset: 4, as: UInt16.self)
        b.storeBytes(of: UInt16(0x301), toByteOffset: 6, as: UInt16.self)
        b.storeBytes(of: UInt8(AF_UNSPEC), toByteOffset: 16, as: UInt8.self)
    }
    guard send(fd, req, 32, 0) == 32 else { return ["netlink send failed"] }
    var names: [String] = []
    var buf = [UInt8](repeating: 0, count: 32768)
    while true {
        let n = recv(fd, &buf, buf.count, 0)
        guard n > 0 else { break }
        var off = 0
        while off + 16 <= n {
            let len = Int(buf.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt32.self) })
            let type = buf.withUnsafeBytes { $0.load(fromByteOffset: off + 4, as: UInt16.self) }
            if type == 3 /* NLMSG_DONE */ || len < 16 { return names }
            var a = off + 32 // attributes after ifinfomsg
            while a + 4 <= off + len {
                let alen = Int(buf.withUnsafeBytes { $0.load(fromByteOffset: a, as: UInt16.self) })
                let atype = buf.withUnsafeBytes { $0.load(fromByteOffset: a + 2, as: UInt16.self) }
                if alen < 4 { break }
                if atype == 3 /* IFLA_IFNAME */ { names.append(String(decoding: buf[(a + 4)..<(a + alen - 1)], as: UTF8.self)) }
                a += (alen + 3) & ~3
            }
            off += (len + 3) & ~3
        }
    }
    return names
}

func run(_ argv: [String]) -> String {
    var fds: [Int32] = [0, 0]
    pipe(&fds)
    var actions = posix_spawn_file_actions_t()
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
    posix_spawn_file_actions_adddup2(&actions, fds[1], 2)
    var cargs = argv.map { strdup($0) } + [nil]
    var pid: pid_t = 0
    let rc = posix_spawnp(&pid, argv[0], &actions, nil, &cargs, nil)
    close(fds[1])
    guard rc == 0 else { return "spawn failed \(rc)" }
    var out = [UInt8](), chunk = [UInt8](repeating: 0, count: 4096)
    while case let n = read(fds[0], &chunk, chunk.count), n > 0 { out += chunk[0..<n] }
    close(fds[0]); var status: Int32 = 0; waitpid(pid, &status, 0)
    return String(decoding: out, as: UTF8.self).trimmingCharacters()
}
extension String { func trimmingCharacters() -> String { String(self.split(separator: "\n").joined(separator: " ")) } }

func listenVsock(_ port: UInt32) -> Int32 {
    let s = socket(40 /* AF_VSOCK */, Int32(SOCK_STREAM), 0)
    // sockaddr_vm: family u16, reserved u16, port u32, cid u32, flags + zero[3]
    var addr = [UInt8](repeating: 0, count: 16)
    addr.withUnsafeMutableBytes { b in
        b.storeBytes(of: UInt16(40), toByteOffset: 0, as: UInt16.self)
        b.storeBytes(of: port, toByteOffset: 4, as: UInt32.self)
        b.storeBytes(of: UInt32.max, toByteOffset: 8, as: UInt32.self) // VMADDR_CID_ANY
    }
    let bound = addr.withUnsafeBytes { bind(s, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), 16) }
    guard s >= 0, bound == 0, listen(s, 4) == 0 else { print("agent: vsock \(port) listen failed errno \(errno)"); exit(1) }
    print("agent: listening on vsock \(port)")
    return s
}


// Copies both ways until either side closes.
func relay(_ a: Int32, _ b: Int32, frames: Bool = false, pty: Int32 = -1) {
    var fds = [pollfd(fd: a, events: Int16(POLLIN), revents: 0), pollfd(fd: b, events: Int16(POLLIN), revents: 0)]
    var buf = [UInt8](repeating: 0, count: 65536)
    var pending = [UInt8]()
    while poll(&fds, 2, -1) > 0 {
        for i in 0..<2 where fds[i].revents != 0 {
            let n = read(fds[i].fd, &buf, buf.count)
            if n <= 0 { return }
            if i == 0 && frames { pending += buf[0..<n]; pending = deframe(pending, to: b, pty: pty) }
            else { _ = writeAll(i == 0 ? b : a, Array(buf[0..<n])) }
        }
    }
}
@discardableResult func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var off = 0
    while off < bytes.count { let w = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, bytes.count - off) }; if w <= 0 { return false }; off += w }
    return true
}
// pty input frames: [0][u16 len][bytes] = keyboard, [1][u16 rows][u16 cols] = resize. Returns leftover bytes.
func deframe(_ b: [UInt8], to fd: Int32, pty: Int32) -> [UInt8] {
    var i = 0
    func u16(_ at: Int) -> Int { Int(b[at]) << 8 | Int(b[at + 1]) }
    while i + 3 <= b.count {
        if b[i] == 0 {
            let len = u16(i + 1)
            guard i + 3 + len <= b.count else { break }
            writeAll(fd, Array(b[(i + 3)..<(i + 3 + len)])); i += 3 + len
        } else {
            guard i + 5 <= b.count else { break }
            var ws = winsize(ws_row: UInt16(u16(i + 1)), ws_col: UInt16(u16(i + 3)), ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(pty, UInt(TIOCSWINSZ), &ws); i += 5
        }
    }
    return Array(b[i...])
}
func connectVsock(cid: UInt32, port: UInt32) -> Int32 {
    let s = socket(40, Int32(SOCK_STREAM), 0)
    var addr = [UInt8](repeating: 0, count: 16)
    addr.withUnsafeMutableBytes { b in
        b.storeBytes(of: UInt16(40), toByteOffset: 0, as: UInt16.self)
        b.storeBytes(of: port, toByteOffset: 4, as: UInt32.self)
        b.storeBytes(of: cid, toByteOffset: 8, as: UInt32.self)
    }
    let rc = addr.withUnsafeBytes { connect(s, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), 16) }
    return rc == 0 ? s : -1
}

// Spike 0.11: `agent pty` serves a login shell per vsock 1026 connection; `agent sshfwd` exposes
// /run/v2mac-ssh-agent.sock and carries each connection to the host's ssh-agent on vsock 2:1027.
switch CommandLine.arguments.dropFirst().first {
case "pty":
    let s = listenVsock(1026)
    signal(SIGCHLD, SIG_IGN)
    while true {
        let c = accept(s, nil, nil)
        if c < 0 { continue }
        if fork() == 0 {
            var master: Int32 = 0
            let pid = forkpty(&master, nil, nil, nil)
            if pid == 0 {
                setenv("SSH_AUTH_SOCK", "/run/v2mac-ssh-agent.sock", 1); setenv("TERM", "xterm-256color", 1); setenv("HOME", "/root", 1)
                chdir("/root")
                var argv: [UnsafeMutablePointer<CChar>?] = [strdup("bash"), strdup("-l"), nil]; execv("/bin/bash", &argv)
                exit(127)
            }
            relay(c, master, frames: true, pty: master)
            kill(pid, SIGHUP); exit(0)
        }
        close(c)
    }
case "sshfwd":
    let path = "/run/v2mac-ssh-agent.sock"
    unlink(path)
    let s = socket(AF_UNIX, Int32(SOCK_STREAM), 0)
    var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { p in for (i, ch) in path.utf8.enumerated() { p[i] = ch } }
    let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
    guard ok, listen(s, 8) == 0 else { print("agent: ssh socket failed errno \(errno)"); exit(1) }
    chmod(path, 0o600) // shortcut: root only; the real agent bind-mounts it only into the approved pod, owned by its user
    print("agent: ssh-agent forward on \(path)")
    signal(SIGCHLD, SIG_IGN)
    while true {
        let c = accept(s, nil, nil)
        if c < 0 { continue }
        if fork() == 0 {
            let v = connectVsock(cid: 2, port: 1027)
            if v >= 0 { relay(c, v) }
            exit(0)
        }
        close(c)
    }
case "fwd":
    // Spike 0.7: `agent fwd <vsock port> <unix path>` carries each vsock connection to a local Unix socket (wayvnc).
    let args = CommandLine.arguments
    let s = listenVsock(UInt32(args[2])!)
    signal(SIGCHLD, SIG_IGN)
    while true {
        let c = accept(s, nil, nil)
        if c < 0 { continue }
        if fork() == 0 {
            let u = socket(AF_UNIX, Int32(SOCK_STREAM), 0)
            var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &addr.sun_path) { p in for (i, ch) in args[3].utf8.enumerated() { p[i] = ch } }
            let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(u, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
            if ok { relay(c, u) }
            exit(0)
        }
        close(c)
    }
default: break
}

// Spike 0.4: `agent echo` echoes every connection on vsock 1025 (one child per connection).
if CommandLine.arguments.dropFirst().first == "echo" {
    let s = listenVsock(1025)
    signal(SIGCHLD, SIG_IGN)
    while true {
        let c = accept(s, nil, nil)
        if c < 0 { continue }
        if fork() == 0 {
            var buf = [UInt8](repeating: 0, count: 256 * 1024)
            while case let n = read(c, &buf, buf.count), n > 0 {
                var off = 0
                while off < n { let w = buf[off..<n].withUnsafeBytes { write(c, $0.baseAddress, n - off) }; if w <= 0 { exit(0) }; off += w }
            }
            exit(0)
        }
        close(c)
    }
}

let s = listenVsock(1024)
while true {
    let c = accept(s, nil, nil)
    if c < 0 { continue }
    let reply = "links=\(netlinkLinks().joined(separator: ",")) podman=\(run(["podman", "--version"]))\n"
    _ = reply.withCString { write(c, $0, strlen($0)) }
    close(c)
}
