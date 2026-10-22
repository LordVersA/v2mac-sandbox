// Spike 0.8: keyboard, IME and pointer input for the RFB window.
// Text goes through NSTextInputClient (layouts, dead keys, IMEs), so the guest gets finished characters as
// Unicode keysyms; ⌘ maps to Ctrl; editing commands map to X keys. Trackpad scroll becomes wheel clicks.
import AppKit

enum Keysym {
    static let ret: UInt32 = 0xff0d, backspace: UInt32 = 0xff08, tab: UInt32 = 0xff09, escape: UInt32 = 0xff1b
    static let delete: UInt32 = 0xffff, home: UInt32 = 0xff50, left: UInt32 = 0xff51, up: UInt32 = 0xff52
    static let right: UInt32 = 0xff53, down: UInt32 = 0xff54, pageUp: UInt32 = 0xff55, pageDown: UInt32 = 0xff56
    static let end: UInt32 = 0xff57, shift: UInt32 = 0xffe1, ctrl: UInt32 = 0xffe3, alt: UInt32 = 0xffe9
    static func of(_ s: Unicode.Scalar) -> UInt32 {
        let v = s.value
        return (0x20...0x7e).contains(v) || (0xa0...0xff).contains(v) ? v : 0x0100_0000 + v
    }
}

extension RFBClient {
    func key(_ sym: UInt32, _ down: Bool) { send([4, down ? 1 : 0, 0, 0] + withUnsafeBytes(of: sym.bigEndian) { Array($0) }) }
    /// Presses `sym` with `mods` held, then releases everything.
    func tap(_ sym: UInt32, mods: [UInt32] = []) {
        mods.forEach { key($0, true) }; key(sym, true); key(sym, false); mods.reversed().forEach { key($0, false) }
    }
    func sendText(_ s: String) {
        let line = Array((s.replacingOccurrences(of: "\n", with: " ") + "\n").utf8)
        if textFD < 0 { print("[input] text channel not open"); return }
        _ = line.withUnsafeBytes { write(textFD, $0.baseAddress, line.count) }
    }
    func pointer(_ mask: UInt8, _ x: Int, _ y: Int) { send([5, mask] + be16(max(0, x)) + be16(max(0, y))) }
}

final class InputView: NSView, @preconcurrency NSTextInputClient {
    weak var client: RFBClient?
    var buttons: UInt8 = 0
    var scrollAcc: CGFloat = 0
    var marked = ""
    override var acceptsFirstResponder: Bool { true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    // MARK: keyboard
    override func keyDown(with e: NSEvent) {
        guard let c = client else { return }
        let f = e.modifierFlags
        if f.contains(.command) || f.contains(.control) {
            var mods = [Keysym.ctrl]
            if f.contains(.shift) { mods.append(Keysym.shift) }
            switch e.keyCode {
            case 123: c.tap(Keysym.home, mods: f.contains(.shift) ? [Keysym.shift] : []) // ⌘← = Home
            case 124: c.tap(Keysym.end, mods: f.contains(.shift) ? [Keysym.shift] : [])
            case 51: c.tap(Keysym.home, mods: [Keysym.shift]); c.tap(Keysym.backspace) // ⌘⌫ = delete to line start
            default:
                if let s = e.charactersIgnoringModifiers?.lowercased().unicodeScalars.first { c.tap(Keysym.of(s), mods: mods) }
            }
            return
        }
        interpretKeyEvents([e])
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        marked = ""; window?.subtitle = ""
        // ASCII goes as RFB keysyms; anything else (Persian, IME output, é) over the text channel.
        if s.unicodeScalars.allSatisfy({ $0.isASCII }) { s.unicodeScalars.forEach { client?.tap(Keysym.of($0)) } }
        else { client?.sendText(s) }
    }
    override func doCommand(by sel: Selector) {
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
        if let (sym, mods) = map[NSStringFromSelector(sel)] { client?.tap(sym, mods: mods) }
        else { print("[input] unmapped command \(NSStringFromSelector(sel))") }
    }
    // IME composition stays on the Mac until committed; the spike shows it in the window subtitle.
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        window?.subtitle = marked.isEmpty ? "" : "composing: \(marked)"
    }
    func unmarkText() { marked = ""; window?.subtitle = "" }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: (marked as NSString).length) }
    func hasMarkedText() -> Bool { !marked.isEmpty }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // shortcut: the candidate window sits at the pointer; a real client asks the guest for the caret.
        let p = NSEvent.mouseLocation
        return NSRect(x: p.x, y: p.y - 20, width: 1, height: 20)
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    // MARK: pointer
    func fbPoint(_ e: NSEvent) -> (Int, Int) {
        guard let c = client else { return (0, 0) }
        let p = convert(e.locationInWindow, from: nil)
        return (Int(p.x / bounds.width * CGFloat(c.width)), Int((bounds.height - p.y) / bounds.height * CGFloat(c.height)))
    }
    func sendPointer(_ e: NSEvent) { let (x, y) = fbPoint(e); client?.pointer(buttons, x, y) }
    override func mouseMoved(with e: NSEvent) { sendPointer(e) }
    override func mouseDragged(with e: NSEvent) { sendPointer(e) }
    override func rightMouseDragged(with e: NSEvent) { sendPointer(e) }
    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); buttons |= 1; sendPointer(e) }
    override func mouseUp(with e: NSEvent) { buttons &= ~1; sendPointer(e) }
    override func rightMouseDown(with e: NSEvent) { buttons |= 4; sendPointer(e) }
    override func rightMouseUp(with e: NSEvent) { buttons &= ~4; sendPointer(e) }
    override func otherMouseDown(with e: NSEvent) { buttons |= 2; sendPointer(e) }
    override func otherMouseUp(with e: NSEvent) { buttons &= ~2; sendPointer(e) }
    override func scrollWheel(with e: NSEvent) {
        // One wheel click per 12 points of trackpad travel (or per line of a real wheel).
        scrollAcc += e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 12
        let (x, y) = fbPoint(e)
        while abs(scrollAcc) >= 12 {
            let bit: UInt8 = scrollAcc > 0 ? 8 : 16 // button 4 = up, 5 = down
            client?.pointer(buttons | bit, x, y); client?.pointer(buttons, x, y)
            scrollAcc -= scrollAcc > 0 ? 12 : -12
        }
    }
}
