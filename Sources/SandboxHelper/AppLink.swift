import Foundation
import V2MacCore

/// The helper's end of the socketpair V2Mac launched it with, on fd 3 (plan §2). Messages arrive on
/// the main actor; when the link closes the helper must shut down, since it never outlives V2Mac.
@MainActor final class AppLink {
    static let fd: Int32 = 3

    private let handle = FileHandle(fileDescriptor: AppLink.fd, closeOnDealloc: true)

    /// Fd 3 is a socket only when V2Mac started us.
    static var isPresent: Bool {
        var info = stat()
        return fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
    }

    func start(onMessage: @escaping @MainActor (SandboxLink.ToHelper) -> Void, onClose: @escaping @MainActor () -> Void) {
        nonisolated(unsafe) var reader = SandboxLink.Reader<SandboxLink.ToHelper>()
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            let messages = data.isEmpty ? nil : try? reader.feed(data)
            DispatchQueue.main.async {
                guard let messages else {
                    handle.readabilityHandler = nil
                    return onClose()
                }
                messages.forEach(onMessage)
            }
        }
    }

    func send(_ message: SandboxLink.ToApp) {
        guard let data = try? SandboxLink.frame(message) else { return }
        try? handle.write(contentsOf: data)
    }
}
