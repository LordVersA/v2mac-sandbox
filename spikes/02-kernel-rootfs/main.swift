// Spike 0.2: boot our kernel + erofs rootfs, report time to multi-user and idle RAM.
// Usage: boot <Image> <rootfs.erofs> [ram MB]
import Foundation
import Virtualization

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
do { try config.validate() } catch { print("[spike] invalid config: \(error)"); exit(1) }

let start = Date()
out.fileHandleForReading.readabilityHandler = { h in
    let s = String(decoding: h.availableData, as: UTF8.self)
    FileHandle.standardOutput.write(Data(s.utf8))
    if s.contains("V2MAC-READY") {
        print(String(format: "\n[spike] multi-user reached, host wall clock %.2f s", Date().timeIntervalSince(start)))
        DispatchQueue.main.async(execute: askAgent)
    }
    if s.contains("V2MAC-MEM") { DispatchQueue.main.asyncAfter(deadline: .now() + 20) { exit(0) } }
}
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
vm.start { if case .failure(let e) = $0 { print("[spike] start failed: \(e)"); exit(1) } }
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { print("\n[spike] timeout"); exit(1) }
dispatchMain()
