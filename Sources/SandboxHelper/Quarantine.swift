import CoreServices
import Foundation

/// Files that appear in `~/V2Mac Sandbox` get `com.apple.quarantine` (plan "Files"), so macOS treats
/// what a mini VM wrote like a download. shortcut: FSEvents can't tell who wrote a file, so files the
/// user drops in for the VM are flagged too; harmless, Gatekeeper only asks before running them.
final class QuarantineWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    /// The C callback can't capture; there is one watcher per helper.
    nonisolated(unsafe) static var root = ""
    let folder: URL

    init(folder: URL) { self.folder = folder }

    func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var context = FSEventStreamContext()
        Self.root = folder.resolvingSymlinksInPath().path + "/"
        let callback: FSEventStreamCallback = { _, _, count, paths, flags, _ in
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            for i in 0..<min(count, list.count) {
                let f = Int(flags[i])
                guard f & (kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemIsSymlink) != 0,
                      f & (kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemRenamed
                           | kFSEventStreamEventFlagItemXattrMod) != 0 else { continue } // XattrMod: a removed flag comes back
                QuarantineWatcher.mark(list[i], under: QuarantineWatcher.root)
            }
        }
        stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
        guard let stream else { return log("quarantine watch failed") }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "v2mac.sandbox.quarantine"))
        FSEventStreamStart(stream)
    }

    /// Files, folders (an app bundle is one) and symlinks alike; always our value, so a flag the VM
    /// set itself (say, "already approved") never stands.
    static func mark(_ path: String, under root: String) {
        let name = "com.apple.quarantine"
        let value = String(format: "0083;%08x;V2Mac Sandbox;", Int(Date().timeIntervalSince1970))
        // One descriptor for check and write: the item itself (a symlink is not followed), and only
        // when it still lies under the watched folder.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_SYMLINK | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var real = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &real) == 0, String(cString: real).hasPrefix(root) else { return }
        var current = [CChar](repeating: 0, count: 128)
        let n = fgetxattr(fd, name, &current, current.count - 1, 0, 0)
        if n > 0, case let v = String(cString: current), v.hasPrefix("0083;"), v.hasSuffix(";V2Mac Sandbox;") { return } // ours; stops the event loop
        _ = value.withCString { fsetxattr(fd, name, $0, strlen($0), 0, 0) }
    }
}
