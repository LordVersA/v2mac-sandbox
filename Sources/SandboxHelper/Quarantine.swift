import CoreServices
import Foundation

/// Files that appear in `~/V2Mac Sandbox` get `com.apple.quarantine` (plan "Files"), so macOS treats
/// what a mini VM wrote like a download. shortcut: FSEvents can't tell who wrote a file, so files the
/// user drops in for the VM are flagged too; harmless, Gatekeeper only asks before running them.
final class QuarantineWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    let folder: URL

    init(folder: URL) { self.folder = folder }

    func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var context = FSEventStreamContext()
        let callback: FSEventStreamCallback = { _, _, count, paths, flags, _ in
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            for i in 0..<min(count, list.count) {
                let f = Int(flags[i])
                guard f & kFSEventStreamEventFlagItemIsFile != 0,
                      f & (kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemRenamed) != 0 else { continue }
                QuarantineWatcher.mark(list[i])
            }
        }
        stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
        guard let stream else { return log("quarantine watch failed") }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "v2mac.sandbox.quarantine"))
        FSEventStreamStart(stream)
    }

    static func mark(_ path: String) {
        let name = "com.apple.quarantine"
        guard FileManager.default.fileExists(atPath: path), getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW) < 0 else { return }
        let value = String(format: "0083;%08x;V2Mac Sandbox;", Int(Date().timeIntervalSince1970))
        _ = value.withCString { setxattr(path, name, $0, strlen($0), 0, XATTR_NOFOLLOW) }
    }
}
