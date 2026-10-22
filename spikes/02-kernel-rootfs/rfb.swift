// Spike 0.7: prototype RFB 3.8 client (Raw, CopyRect, DesktopSize) drawing into a CALayer.
// Measures updates/s, MB/s and this process's CPU (the VM runs in its own XPC process).
import AppKit
import QuartzCore
import Virtualization

final class RFBClient {
    let fd: Int32, name: String
    var width = 0, height = 0
    var fb = [UInt8]()
    var updates = 0, bytes = 0
    var running = true
    var textFD: Int32 = -1
    let layer = CALayer()
    var window: NSWindow?
    init(fd: Int32, name: String) { self.fd = fd; self.name = name }

    func readN(_ n: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: n), got = 0
        while got < n {
            let r = out[got...].withUnsafeMutableBytes { read(fd, $0.baseAddress, n - got) }
            if r <= 0 { return nil }
            got += r
        }
        bytes += n
        return out
    }
    func readInto(_ n: Int, at offset: Int) -> Bool {
        var got = 0
        while got < n {
            let r = fb.withUnsafeMutableBytes { read(fd, $0.baseAddress! + offset + got, n - got) }
            if r <= 0 { return false }
            got += r
        }
        bytes += n
        return true
    }
    func send(_ b: [UInt8]) { _ = b.withUnsafeBytes { write(fd, $0.baseAddress, b.count) } }
    func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
    func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    func request(incremental: Bool) { send([3, incremental ? 1 : 0] + be16(0) + be16(0) + be16(width) + be16(height)) }

    func handshake() -> Bool {
        guard let v = readN(12) else { return false }
        print("[rfb] server \(String(decoding: v, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        send(Array("RFB 003.008\n".utf8))
        guard let n = readN(1), n[0] > 0, let types = readN(Int(n[0])), types.contains(1) else { print("[rfb] no None security"); return false }
        send([1])
        guard let res = readN(4), res == [0, 0, 0, 0] else { return false }
        send([1]) // shared
        guard let si = readN(24) else { return false }
        width = u16(si, 0); height = u16(si, 2)
        guard (1...8192).contains(width), (1...8192).contains(height) else { print("[rfb] bad framebuffer size"); return false }
        _ = readN(Int(si[20]) << 24 | Int(si[21]) << 16 | Int(si[22]) << 8 | Int(si[23]))
        // 32 bpp, depth 24, little endian, true colour, max 255 each, shifts r16 g8 b0 = BGRX in memory
        send([0, 0, 0, 0, 32, 24, 0, 1] + be16(255) + be16(255) + be16(255) + [16, 8, 0, 0, 0, 0])
        let encs: [Int32] = [1, 0, -223] // CopyRect, Raw, DesktopSize
        send([2, 0] + be16(encs.count) + encs.flatMap { e in withUnsafeBytes(of: e.bigEndian) { Array($0) } })
        fb = [UInt8](repeating: 0, count: width * height * 4)
        print("[rfb] \(name): \(width)×\(height)")
        return true
    }

    func run(scale: CGFloat) {
        guard handshake() else { print("[rfb] handshake failed"); return }
        DispatchQueue.main.sync { showWindow(scale: scale) }
        request(incremental: false)
        if ProcessInfo.processInfo.environment["V2MAC_SELFTEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                for word in ["Hello ", "سلام دنیا", " 123"] {
                    if word.unicodeScalars.allSatisfy({ $0.isASCII }) { word.unicodeScalars.forEach { self.tap(Keysym.of($0)) } } else { self.sendText(word) }
                    usleep(300_000)
                }
                self.tap(Keysym.ret); self.tap(0x61, mods: [Keysym.ctrl]) // Ctrl+A selects all
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.saveFrame() }
            }
        }
        while running {
            guard let t = readN(1) else { break }
            switch t[0] {
            case 0:
                guard let h = readN(3) else { return }
                for _ in 0..<u16(h, 1) {
                    guard let r = readN(12) else { return }
                    let x = u16(r, 0), y = u16(r, 2), w = u16(r, 4), hh = u16(r, 6)
                    let enc = Int32(bitPattern: UInt32(r[8]) << 24 | UInt32(r[9]) << 16 | UInt32(r[10]) << 8 | UInt32(r[11]))
                    // The guest is untrusted: every rectangle must lie inside the framebuffer.
                    guard enc == -223 || (x + w <= width && y + hh <= height) else { print("[rfb] rectangle outside the framebuffer"); return }
                    switch enc {
                    case 0:
                        if x == 0 && w == width { guard readInto(w * hh * 4, at: y * width * 4) else { return } }
                        else { for row in 0..<hh { guard readInto(w * 4, at: ((y + row) * width + x) * 4) else { return } } }
                    case 1:
                        guard let s = readN(4), u16(s, 0) + w <= width, u16(s, 2) + hh <= height else { print("[rfb] bad CopyRect source"); return }
                        copyRect(sx: u16(s, 0), sy: u16(s, 2), dx: x, dy: y, w: w, h: hh)
                    case -223:
                        guard (1...8192).contains(w), (1...8192).contains(hh) else { print("[rfb] bad desktop size"); return }
                        width = w; height = hh; fb = [UInt8](repeating: 0, count: w * hh * 4)
                    default: print("[rfb] unexpected encoding \(enc)"); return
                    }
                }
                updates += 1
                present()
                request(incremental: true)
            case 2: break
            case 3:
                guard let h = readN(7) else { return }
                _ = readN(Int(h[3]) << 24 | Int(h[4]) << 16 | Int(h[5]) << 8 | Int(h[6]))
            default: print("[rfb] unexpected message \(t[0])"); return
            }
        }
    }
    func copyRect(sx: Int, sy: Int, dx: Int, dy: Int, w: Int, h: Int) {
        let rows = sy < dy ? Array((0..<h).reversed()) : Array(0..<h)
        fb.withUnsafeMutableBytes { p in
            for r in rows { memmove(p.baseAddress! + ((dy + r) * width + dx) * 4, p.baseAddress! + ((sy + r) * width + sx) * 4, w * 4) }
        }
    }
    func present() {
        let data = Data(fb) as CFData
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                            provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        DispatchQueue.main.async { CATransaction.begin(); CATransaction.setDisableActions(true); self.layer.contents = image; CATransaction.commit() }
    }
    func saveFrame() {
        if let img = (layer.contents as! CGImage?), let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "/private/tmp/claude-501/-Users-parsaradfar-Programming-Projects-v2mac/cbc83175-f729-4899-aee1-e94fec6d36e5/scratchpad/frame-\(name).png") as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
        }
    }
    func showWindow(scale: CGFloat) {
        let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: CGFloat(width) / scale, height: CGFloat(height) / scale), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        let view = InputView(); view.client = self
        w.contentView = view
        w.isReleasedWhenClosed = false
        w.title = "V2Mac Sandbox spike 0.7 — \(name)"
        w.contentView!.wantsLayer = true
        layer.frame = w.contentView!.bounds
        layer.contentsScale = scale
        w.contentView!.layer!.addSublayer(layer)
        w.acceptsMouseMovedEvents = true
        w.makeKeyAndOrderFront(nil); w.makeFirstResponder(view)
        NSApplication.shared.activate()
        window = w
    }
}

func cpuSeconds() -> Double {
    var u = rusage(); getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
}
var rfb: RFBClient?
var rfbStart = (Date(), 0.0)
func rfbBegin(_ name: String) {
    (vm.socketDevices.first as? VZVirtioSocketDevice)?.connect(toPort: 1028) { r in
        guard case .success(let c) = r else { print("[rfb] vsock connect failed"); return }
        keep.append(c)
        let client = RFBClient(fd: c.fileDescriptor, name: name)
        rfb = client
        DispatchQueue.main.async { // never connect from inside a connect handler: VZ crashes
            (vm.socketDevices.first as? VZVirtioSocketDevice)?.connect(toPort: 1029) { r in
                if case .success(let t) = r { keep.append(t); client.textFD = t.fileDescriptor }
            }
        }
        rfbStart = (Date(), cpuSeconds())
        Thread.detachNewThread { client.run(scale: name.hasSuffix("2x") ? 2 : 1) }
    }
}
func rfbEnd() {
    guard let c = rfb else { return }
    let s = Date().timeIntervalSince(rfbStart.0), cpu = cpuSeconds() - rfbStart.1
    print(String(format: "[rfb] %@: %.1f updates/s, %.1f MB/s, host client CPU %.0f%% of one core", c.name, Double(c.updates) / s, Double(c.bytes) / s / 1e6, cpu / s * 100))
    c.saveFrame()
    c.running = false; shutdown(c.fd, SHUT_RDWR)
    DispatchQueue.main.async { c.window?.close() }
    rfb = nil
}
