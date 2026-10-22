// Spike 0.2: boot our kernel + erofs rootfs, report time to multi-user and idle RAM.
// Usage: boot <Image> <rootfs.erofs> [ram MB]
import Foundation
import Virtualization
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: boot <Image> <rootfs.erofs> [ram MB]"); exit(2) }
setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

let boot = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: args[1]))
boot.commandLine = "console=hvc0 root=/dev/vda rootfstype=erofs ro init=/sbin/overlay-init quiet"
let config = VZVirtualMachineConfiguration()
config.bootLoader = boot
config.cpuCount = 2
config.memorySize = UInt64(args.count > 3 ? Int(args[3])! : 1024) << 20
let disk = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: args[2]), readOnly: true)
config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]
let out = Pipe()
let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: out.fileHandleForWriting)
config.serialPorts = [serial]
config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
let sound = VZVirtioSoundDeviceConfiguration()
let speaker = VZVirtioSoundDeviceOutputStreamConfiguration()
speaker.sink = VZHostAudioOutputStreamSink()
sound.streams = [speaker]
config.audioDevices = [sound]
do { try config.validate() } catch { print("[spike] invalid config: \(error)"); exit(1) }

let start = Date()
out.fileHandleForReading.readabilityHandler = { h in
    let s = String(decoding: h.availableData, as: UTF8.self)
    FileHandle.standardOutput.write(Data(s.utf8))
    if s.contains("V2MAC-READY") {
        print(String(format: "\n[spike] multi-user reached, host wall clock %.2f s", Date().timeIntervalSince(start)))
        DispatchQueue.main.async(execute: askAgent)
    }
    if s.contains("S05 done") { print("[spike] S05 done") }
    if s.contains("S09 done") { print("[spike] S09 done") }
    for line in s.split(separator: "\n") where line.contains("S07 ") || line.contains("S08 ") {
        let words = line.split(separator: " ")
        guard let i = words.firstIndex(where: { $0 == "S07" || $0 == "S08" }), i + 2 < words.count else { continue }
        let phase = String(words[i + 2]).trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        DispatchQueue.main.async {
            if words[i + 1] == "ready" { rfbBegin(phase) }
            if words[i + 1] == "end" { rfbEnd() }
        }
    }
}
// Spike 0.11: Unix socket for v2mac-pty → vsock 1026 (guest pty), and vsock 1027 from the guest → host ssh-agent.
var keep: [AnyObject] = []
func pipeBoth(_ a: Int32, _ b: Int32) {
    for (from, to) in [(a, b), (b, a)] {
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 65536)
            while case let n = read(from, &buf, buf.count), n > 0 { if write(to, buf, n) != n { break } }
            shutdown(to, SHUT_WR)
        }
    }
}
func unixSocket(_ path: String, listen doListen: Bool) -> Int32 {
    let s = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { p in for (i, ch) in path.utf8.enumerated() { p[i] = ch } }
    let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        doListen ? bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) : connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    if rc != 0 { return -1 }
    if doListen { Darwin.listen(s, 8) }
    return s
}
func servePty() {
    let path = NSTemporaryDirectory() + "v2mac-pty-spike.sock" // per-user, 0700 dir
    unlink(path)
    let s = unixSocket(path, listen: true)
    guard s >= 0 else { print("[spike] pty socket bind failed"); exit(1) }
    chmod(path, 0o600)
    print("[spike] pty socket \(path)")
    Thread.detachNewThread {
        while true {
            let c = accept(s, nil, nil)
            if c < 0 { continue }
            DispatchQueue.main.async {
                (vm.socketDevices.first as? VZVirtioSocketDevice)?.connect(toPort: 1026) { r in
                    guard case .success(let v) = r else { print("[spike] pty vsock failed"); close(c); return }
                    keep.append(v); pipeBoth(c, v.fileDescriptor)
                }
            }
        }
    }
}
final class SSHForward: NSObject, VZVirtioSocketListenerDelegate {
    func listener(_ l: VZVirtioSocketListener, shouldAcceptNewConnection c: VZVirtioSocketConnection, from d: VZVirtioSocketDevice) -> Bool {
        guard let path = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] else { return false }
        let s = unixSocket(path, listen: false)
        guard s >= 0 else { return false }
        keep.append(c); pipeBoth(c.fileDescriptor, s)
        return true
    }
}
let sshForward = SSHForward()

// Spike 0.4: latency (1-byte ping-pong) and duplex throughput over vsock 1025 (agent echo).
func measure() {
    (vm.socketDevices.first as? VZVirtioSocketDevice)?.connect(toPort: 1025) { result in
        guard case .success(let c) = result else { print("[spike] echo connect failed"); return }
        Thread.detachNewThread {
            let fd = c.fileDescriptor
            var b: UInt8 = 1
            let rounds = 5000
            var t = Date()
            for i in 0..<rounds { guard write(fd, &b, 1) == 1, read(fd, &b, 1) == 1 else { print("[spike] ping-pong broke at \(i), errno \(errno)"); return } }
            print(String(format: "[spike] vsock round trip: %.1f µs", Date().timeIntervalSince(t) / Double(rounds) * 1e6))
            let total = 1 << 30
            t = Date()
            Thread.detachNewThread {
                var buf = [UInt8](repeating: 7, count: 256 * 1024), sent = 0
                while sent < total { sent += max(0, write(fd, &buf, min(buf.count, total - sent))) }
            }
            var buf = [UInt8](repeating: 0, count: 256 * 1024), got = 0
            while got < total { let n = read(fd, &buf, buf.count); if n <= 0 { break }; got += n }
            let s = Date().timeIntervalSince(t)
            print(String(format: "[spike] vsock echo: 1 GiB each way in %.2f s = %.0f Mbit/s per direction", s, Double(got) * 8 / s / 1e6))
            _ = c
        }
    }
}

// Spike 0.3: one request to the agent over vsock 1024.
func askAgent() {
    (vm.socketDevices.first as? VZVirtioSocketDevice)?.connect(toPort: 1024) { result in
        switch result {
        case .success(let c):
            let data = FileHandle(fileDescriptor: c.fileDescriptor).readDataToEndOfFile()
            print("[spike] agent says: \(String(decoding: data, as: UTF8.self))", terminator: "")
            DispatchQueue.main.async(execute: measure)
        case .failure(let e): print("[spike] vsock connect failed: \(e)")
        }
    }
}
let vm = VZVirtualMachine(configuration: config)
vm.start {
    if case .failure(let e) = $0 { print("[spike] start failed: \(e)"); exit(1) }
    let l = VZVirtioSocketListener(); l.delegate = sshForward
    (vm.socketDevices.first as? VZVirtioSocketDevice)?.setSocketListener(l, forPort: 1027)
    keep.append(l); servePty()
}
NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.run()
