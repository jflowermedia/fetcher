// Renders the 1024×1024 app icon PNG: red rounded square with a white download arrow.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1),
           ending: NSColor(red: 0.80, green: 0.05, blue: 0.10, alpha: 1))!.draw(in: bg, angle: -90)

NSColor.white.setFill()
let c = size / 2
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: c - 70, y: 700))
arrow.line(to: NSPoint(x: c + 70, y: 700))
arrow.line(to: NSPoint(x: c + 70, y: 480))
arrow.line(to: NSPoint(x: c + 190, y: 480))
arrow.line(to: NSPoint(x: c, y: 290))
arrow.line(to: NSPoint(x: c - 190, y: 480))
arrow.line(to: NSPoint(x: c - 70, y: 480))
arrow.close()
arrow.fill()
NSBezierPath(roundedRect: NSRect(x: c - 230, y: 200, width: 460, height: 56), xRadius: 28, yRadius: 28).fill()
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
