import AgentProtocol
import Foundation
import Virtualization

/// The one hidden Linux VM (plan §3): read-only erofs rootfs and kernel from the helper bundle, a
/// sparse data disk in `<data>/sandbox/`, vsock, entropy and a balloon. No network device.
@MainActor final class SandboxVM: NSObject, VZVirtualMachineDelegate {
    enum State: String { case stopped, booting, running, stopping }

    private(set) var state = State.stopped { didSet { if state != oldValue { onState(state) } } }
    var onState: (State) -> Void = { _ in }
    /// Shut down this long after the last user (window or app) is gone (plan: "Resources").
    var idleDelay: Duration = .seconds(5 * 60)

    private let root: URL
    private var vm: VZVirtualMachine?
    private var agent: VZVirtioSocketConnection?
    private var users = 0
    private var idleTask: Task<Void, Never>?
    private var console: FileHandle?
    private let agentQueue = DispatchQueue(label: "v2mac.sandbox.agent")

    var socketDevice: VZVirtioSocketDevice? { vm?.socketDevices.first as? VZVirtioSocketDevice }

    /// Each mini VM's Shared folder by id (plan "Files"), seen in the VM as `/exchange/<id>`. Set again
    /// whenever mini VMs change; the running VM picks it up without a restart.
    var shares: [String: URL] = [:] {
        didSet { (vm?.directorySharingDevices.first as? VZVirtioFileSystemDevice)?.share = share }
    }
    private var share: VZMultipleDirectoryShare {
        VZMultipleDirectoryShare(directories: shares.reduce(into: [:]) { $0[$1.key] = VZSharedDirectory(url: $1.value, readOnly: $1.key == "_cache") })
    }

    /// Sends one request to the agent and waits for its answer; nil when the VM is down or the agent
    /// says something unexpected. Requests are answered in order, one at a time, so `timeoutMS` must
    /// outlast the slowest answer: a late one would be read as the next request's.
    func call(_ message: AgentMessage, timeoutMS: Int32 = 180_000) async -> AgentMessage? {
        guard state == .running, let fd = agent?.fileDescriptor else { return nil }
        return await withCheckedContinuation { continuation in
            agentQueue.async {
                let frame = message.frame
                let sent = frame.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == frame.count
                continuation.resume(returning: sent ? Self.readMessage(fd, timeoutMS: timeoutMS) : nil)
            }
        }
    }

    private nonisolated static func readMessage(_ fd: Int32, timeoutMS: Int32) -> AgentMessage? {
        var reader = AgentMessage.Reader()
        var buf = [UInt8](repeating: 0, count: 16384)
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while poll(&poller, 1, timeoutMS) > 0 {
            let n = read(fd, &buf, buf.count)
            guard n > 0, let messages = try? reader.feed(buf[0..<n]) else { return nil }
            if let first = messages.first { return first }
        }
        return nil
    }

    init(root: URL) { self.root = root }

    var dataDisk: URL { root.appendingPathComponent("data.img") }
    static let dataDiskSize: UInt64 = 64 << 30

    /// A window or app starts using the VM: boots it if needed and cancels a pending idle shutdown.
    func retain(ramCapMB: Int) {
        users += 1
        idleTask?.cancel()
        if state == .stopped { boot(ramCapMB: ramCapMB) }
    }

    func release() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        idleTask?.cancel()
        idleTask = Task { [idleDelay] in
            try? await Task.sleep(for: idleDelay)
            if !Task.isCancelled { await self.stop() }
        }
    }

    func boot(ramCapMB: Int) {
        guard state == .stopped else { return }
        state = .booting
        do {
            let vm = VZVirtualMachine(configuration: try configuration(ramCapMB: ramCapMB))
            vm.delegate = self
            self.vm = vm
            vm.start { result in
                if case .failure(let error) = result { log("VM did not start: \(error.localizedDescription)"); self.reset() }
                else { self.connectAgent(deadline: .now + .seconds(30)) }
            }
        } catch {
            log("VM configuration failed: \(error.localizedDescription)")
            reset()
        }
    }

    /// Asks the agent to power off (so the data disk is flushed), then forces it after 10 seconds.
    func stop() async {
        guard let vm, state == .booting || state == .running else { return }
        state = .stopping
        if let agent { _ = AgentMessage.shutdown.frame.withUnsafeBytes { write(agent.fileDescriptor, $0.baseAddress, $0.count) } }
        for _ in 0..<100 where vm.state != .stopped { try? await Task.sleep(for: .milliseconds(100)) }
        if vm.state != .stopped { try? await vm.stop() }
        reset()
    }

    private func configuration(ramCapMB: Int) throws -> VZVirtualMachineConfiguration {
        let resources = Bundle.main.resourceURL!
        let boot = VZLinuxBootLoader(kernelURL: resources.appendingPathComponent("Image"))
        boot.commandLine = "console=hvc0 root=/dev/vda rootfstype=erofs ro init=/sbin/overlay-init quiet"
        let config = VZVirtualMachineConfiguration()
        config.bootLoader = boot
        config.cpuCount = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        config.memorySize = UInt64(ramCapMB) << 20
        try makeDataDisk()
        config.storageDevices = [
            VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(
                url: resources.appendingPathComponent("rootfs.erofs"), readOnly: true)),
            VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: dataDisk, readOnly: false)),
        ]
        let log = root.appendingPathComponent("vm.log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        console = try FileHandle(forWritingTo: log)
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: console)
        config.serialPorts = [serial]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        let fs = VZVirtioFileSystemDeviceConfiguration(tag: "shared")
        fs.share = share
        config.directorySharingDevices = [fs]
        // Output only: the VM gets no microphone.
        let speaker = VZVirtioSoundDeviceOutputStreamConfiguration()
        speaker.sink = VZHostAudioOutputStreamSink()
        let sound = VZVirtioSoundDeviceConfiguration()
        sound.streams = [speaker]
        config.audioDevices = [sound]
        try config.validate()
        return config
    }

    /// Sparse file; the guest formats it on first boot (rootfs `v2mac-data.service`).
    private func makeDataDisk() throws {
        guard !FileManager.default.fileExists(atPath: dataDisk.path) else { return }
        FileManager.default.createFile(atPath: dataDisk.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: dataDisk)
        defer { try? handle.close() }
        try handle.truncate(atOffset: Self.dataDiskSize)
    }

    /// The agent starts late in boot, so connecting is retried until it says hello.
    private func connectAgent(deadline: ContinuousClock.Instant) {
        guard state == .booting, let device = vm?.socketDevices.first as? VZVirtioSocketDevice else { return }
        device.connect(toPort: AgentMessage.port) { result in
            nonisolated(unsafe) var said: VZVirtioSocketConnection?
            if case .success(let connection) = result, Self.readHello(connection.fileDescriptor) { said = connection }
            // Hop to the main queue before the next connect: a connect from inside a handler crashes VZ (M0 0.4).
            DispatchQueue.main.async {
                if let connection = said {
                    self.agent = connection
                    self.state = .running
                } else if ContinuousClock.now < deadline {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.connectAgent(deadline: deadline) }
                } else {
                    log("the agent did not answer within 30 seconds")
                    Task { await self.stop() }
                }
            }
        }
    }

    private nonisolated static func readHello(_ fd: Int32) -> Bool {
        readMessage(fd, timeoutMS: 2000) == .hello(version: AgentMessage.version)
    }

    private func reset() {
        agent = nil
        vm = nil
        try? console?.close()
        console = nil
        state = .stopped
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in if self.state != .stopping { self.reset() } }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        Task { @MainActor in
            log("VM stopped: \(error.localizedDescription)")
            self.reset()
        }
    }
}

func log(_ text: String) { print("[v2mac-sandbox] \(text)") }
