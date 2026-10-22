import AppKit
import RFB

enum Keysym {
    static let ret: UInt32 = 0xff0d, backspace: UInt32 = 0xff08, tab: UInt32 = 0xff09, escape: UInt32 = 0xff1b
    static let delete: UInt32 = 0xffff, home: UInt32 = 0xff50, left: UInt32 = 0xff51, up: UInt32 = 0xff52
    static let right: UInt32 = 0xff53, down: UInt32 = 0xff54, pageUp: UInt32 = 0xff55, pageDown: UInt32 = 0xff56
    static let end: UInt32 = 0xff57, shift: UInt32 = 0xffe1, ctrl: UInt32 = 0xffe3
    static func of(_ s: Unicode.Scalar) -> UInt32 {
        let v = s.value
        return (0x20...0x7e).contains(v) || (0xa0...0xff).contains(v) ? v : 0x0100_0000 + v
    }
}

/// Draws the framebuffer and turns Mac input into RFB (M0 0.8): text through `NSTextInputClient`
/// (layouts, dead keys, IMEs), ASCII as keysyms and everything else as our text message; ⌘ maps to
/// Ctrl; trackpad scroll becomes wheel clicks. Clipboard (plan "Clipboard"): Mac → app only on ⌘V,
/// app → Mac when it copies and `copyOut` allows it.
final class RFBView: NSView, @preconcurrency NSTextInputClient {
    let client: RFBClient
    let copyOut: Bool
    private var buttons: UInt8 = 0
    private var scroll: CGFloat = 0
    private var marked = ""

    init(client: RFBClient, copyOut: Bool) {
        self.client = client
        self.copyOut = copyOut
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .nearest
        client.onFrame = { [weak self] c in
            let image = Self.image(c)
            DispatchQueue.main.async {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                self?.layer?.contents = image
                CATransaction.commit()
            }
        }
        client.onCutText = { [weak self] text in
            guard self?.copyOut == true else { return }
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    static func image(_ c: RFBClient) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(c.framebuffer) as CFData) else { return nil }
        return CGImage(width: c.width, height: c.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: c.width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The window's size in pixels becomes the app's output size.
    func sendSize() {
        let scale = Int(window?.backingScaleFactor ?? 2) >= 2 ? 2 : 1
        client.requestSize(width: Int(bounds.width) * scale, height: Int(bounds.height) * scale, scale: scale)
    }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    @objc func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) { client.cutText(text) }
        client.tap(0x76, mods: [Keysym.ctrl])
    }

    // MARK: Keyboard

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        // ⌘Q/⌘H/⌘M/⌘W stay Mac commands; every other ⌘ shortcut goes to the app as Ctrl.
        guard e.modifierFlags.contains(.command), let k = e.charactersIgnoringModifiers?.lowercased() else { return false }
        if ["q", "h", "m", "w"].contains(k) { return super.performKeyEquivalent(with: e) }
        if k == "v" { paste(nil); return true }
        keyDown(with: e)
        return true
    }

    override func keyDown(with e: NSEvent) {
        let f = e.modifierFlags
        guard f.contains(.command) || f.contains(.control) else { return interpretKeyEvents([e]) }
        var mods = [Keysym.ctrl]
        if f.contains(.shift) { mods.append(Keysym.shift) }
        switch e.keyCode {
        case 123: client.tap(Keysym.home, mods: f.contains(.shift) ? [Keysym.shift] : []) // ⌘← = Home
        case 124: client.tap(Keysym.end, mods: f.contains(.shift) ? [Keysym.shift] : [])
        case 51: client.tap(Keysym.home, mods: [Keysym.shift]); client.tap(Keysym.backspace) // ⌘⌫
        default:
            if let s = e.charactersIgnoringModifiers?.lowercased().unicodeScalars.first { client.tap(Keysym.of(s), mods: mods) }
        }
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        unmarkText()
        if s.unicodeScalars.allSatisfy(\.isASCII) { s.unicodeScalars.forEach { client.tap(Keysym.of($0)) } }
        else { client.text(s) }
    }

    override func doCommand(by selector: Selector) {
        let shift = [Keysym.shift], word = [Keysym.ctrl]
        let map: [String: (UInt32, [UInt32])] = [
            "insertNewline:": (Keysym.ret, []), "insertLineBreak:": (Keysym.ret, shift), "deleteBackward:": (Keysym.backspace, []),
            "deleteForward:": (Keysym.delete, []), "insertTab:": (Keysym.tab, []), "insertBacktab:": (Keysym.tab, shift),
            "cancelOperation:": (Keysym.escape, []), "deleteWordBackward:": (Keysym.backspace, word),
            "moveLeft:": (Keysym.left, []), "moveRight:": (Keysym.right, []), "moveUp:": (Keysym.up, []), "moveDown:": (Keysym.down, []),
            "moveLeftAndModifySelection:": (Keysym.left, shift), "moveRightAndModifySelection:": (Keysym.right, shift),
            "moveUpAndModifySelection:": (Keysym.up, shift), "moveDownAndModifySelection:": (Keysym.down, shift),
            "moveWordLeft:": (Keysym.left, word), "moveWordRight:": (Keysym.right, word),
            "moveWordLeftAndModifySelection:": (Keysym.left, word + shift), "moveWordRightAndModifySelection:": (Keysym.right, word + shift),
            "moveToBeginningOfLine:": (Keysym.home, []), "moveToEndOfLine:": (Keysym.end, []),
            "scrollPageUp:": (Keysym.pageUp, []), "scrollPageDown:": (Keysym.pageDown, []),
            "pageUp:": (Keysym.pageUp, []), "pageDown:": (Keysym.pageDown, []),
        ]
        if let (sym, mods) = map[NSStringFromSelector(selector)] { client.tap(sym, mods: mods) }
    }

    // IME composition stays on the Mac until committed; shown in the window subtitle meanwhile.
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString)?.string ?? string as? String ?? ""
    }
    func unmarkText() { marked = "" }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: (marked as NSString).length) }
    func hasMarkedText() -> Bool { !marked.isEmpty }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // shortcut: the candidate window sits at the pointer; the guest's caret isn't known here.
        let p = NSEvent.mouseLocation
        return NSRect(x: p.x, y: p.y - 20, width: 1, height: 20)
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    // MARK: Pointer

    private func point(_ e: NSEvent) -> (Int, Int) {
        let p = convert(e.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return (0, 0) }
        return (Int(p.x / bounds.width * CGFloat(client.width)), Int((bounds.height - p.y) / bounds.height * CGFloat(client.height)))
    }
    private func send(_ e: NSEvent) { let (x, y) = point(e); client.pointer(buttons: buttons, x: x, y: y) }
    override func mouseMoved(with e: NSEvent) { send(e) }
    override func mouseDragged(with e: NSEvent) { send(e) }
    override func rightMouseDragged(with e: NSEvent) { send(e) }
    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); buttons |= 1; send(e) }
    override func mouseUp(with e: NSEvent) { buttons &= ~1; send(e) }
    override func rightMouseDown(with e: NSEvent) { buttons |= 4; send(e) }
    override func rightMouseUp(with e: NSEvent) { buttons &= ~4; send(e) }
    override func otherMouseDown(with e: NSEvent) { buttons |= 2; send(e) }
    override func otherMouseUp(with e: NSEvent) { buttons &= ~2; send(e) }
    override func scrollWheel(with e: NSEvent) {
        // One wheel click per 12 points of trackpad travel (or per line of a real wheel).
        scroll += e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 12
        let (x, y) = point(e)
        while abs(scroll) >= 12 {
            let bit: UInt8 = scroll > 0 ? 8 : 16
            client.pointer(buttons: buttons | bit, x: x, y: y)
            client.pointer(buttons: buttons, x: x, y: y)
            scroll -= scroll > 0 ? 12 : -12
        }
    }
}
