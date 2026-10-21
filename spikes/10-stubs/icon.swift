// Draws a 1024 px tinted rounded square as a stand-in for the plugin icon. Usage: icon <hue 0-1> <out.png>
import AppKit
let hue = CGFloat(Double(CommandLine.arguments[1])!)
let img = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { r in
    NSColor(hue: hue, saturation: 0.7, brightness: 0.9, alpha: 1).setFill()
    NSBezierPath(roundedRect: r.insetBy(dx: 100, dy: 100), xRadius: 180, yRadius: 180).fill()
    return true
}
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
