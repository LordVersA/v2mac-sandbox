import Foundation
import Virtualization

/// Host end of a mini VM's relay (plan §4): each guest connection on vsock port 11000+n is piped to
/// the sandbox core's VLESS inbound for that mini VM.
final class RelayListener: NSObject, VZVirtioSocketListenerDelegate, @unchecked Sendable {
    /// The sandbox core's inbound port; changes when the core restarts.
    nonisolated(unsafe) var port: Int
    let listener = VZVirtioSocketListener()

    init(port: Int) {
        self.port = port
        super.init()
        listener.delegate = self
    }

    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        let guest = dup(connection.fileDescriptor)
        connection.close()
        let host = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                               sin_port: in_port_t(UInt16(port).bigEndian), sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(host, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard guest >= 0, host >= 0, connected == 0 else {
            close(guest); close(host)
            return true // the guest sees the connection close: fail closed
        }
        Self.pipe(guest, host)
        return true
    }

    /// shortcut: two blocking threads per connection; move to a kqueue loop if thread count bites.
    static func pipe(_ a: Int32, _ b: Int32) {
        let group = DispatchGroup()
        for (from, to) in [(a, b), (b, a)] {
            group.enter()
            Thread {
                var buf = [UInt8](repeating: 0, count: 65536)
                copy: while case let n = read(from, &buf, buf.count), n > 0 {
                    var off = 0
                    while off < n {
                        let w = buf[off..<n].withUnsafeBytes { write(to, $0.baseAddress, $0.count) }
                        if w <= 0 { break copy }
                        off += w
                    }
                }
                shutdown(to, SHUT_WR)
                group.leave()
            }.start()
        }
        group.notify(queue: .global()) { close(a); close(b) }
    }
}
