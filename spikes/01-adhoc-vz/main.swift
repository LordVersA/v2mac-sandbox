// Spike 0.1: an ad-hoc signed binary with com.apple.security.virtualization boots a Linux VM.
// Usage: helper <kernel> <initrd>. Prints the serial console; exits 0 once the guest kernel has printed.
import Foundation
import Virtualization

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: helper <kernel> <initrd>"); exit(2) }
setvbuf(stdout, nil, _IOLBF, 0)

let boot = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: args[1]))
boot.initialRamdiskURL = URL(fileURLWithPath: args[2])
boot.commandLine = "console=hvc0"
let config = VZVirtualMachineConfiguration()
config.bootLoader = boot
config.cpuCount = 2
config.memorySize = 1 << 30
let out = Pipe()
let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: out.fileHandleForWriting)
config.serialPorts = [serial]
config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
do { try config.validate() } catch { print("[spike] invalid config: \(error)"); exit(1) }

let start = Date()
var seen = ""
out.fileHandleForReading.readabilityHandler = { h in
    let s = String(decoding: h.availableData, as: UTF8.self)
    FileHandle.standardOutput.write(Data(s.utf8))
    seen += s
    if seen.contains("Run /init") {
        print(String(format: "\n[spike] guest reached init after %.2f s", Date().timeIntervalSince(start)))
        exit(0)
    }
}
let vm = VZVirtualMachine(configuration: config)
vm.start { result in
    if case .failure(let e) = result { print("[spike] start failed: \(e)"); exit(1) }
    print("[spike] VM started")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("\n[spike] timeout"); exit(1) }
dispatchMain()
