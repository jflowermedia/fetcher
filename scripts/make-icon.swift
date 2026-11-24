// Draws Fetcher's app icon (1024x1024): a play button with a download arrow on it, in
// Catppuccin Mocha, with a little glass to it, to match Keeper's and Paper's.
// https://catppuccin.com/palette/
//
// build.sh reruns this whenever it changes.
import AppKit
import CoreImage

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: Palette

func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat(hex >> 16 & 255) / 255,
                                            CGFloat(hex >> 8 & 255) / 255,
                                            CGFloat(hex & 255) / 255, alpha])!
}

let green: UInt32 = 0xa6e3a1, teal: UInt32 = 0x94e2d5
let subtext: UInt32 = 0xbac2de, overlay: UInt32 = 0x7f849c, surface2: UInt32 = 0x585b70
let surface1: UInt32 = 0x45475a, surface0: UInt32 = 0x313244, base: UInt32 = 0x1e1e2e
let mantle: UInt32 = 0x181825, crust: UInt32 = 0x11111b
let white: UInt32 = 0xffffff
/// Green, deep enough to be its own shadow. Crust over the button goes grey.
let pine: UInt32 = 0x1b4f43

// MARK: Drawing

func canvas() -> CGContext {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // y down, so the coordinates read like the design's.
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: 1, y: -1)
    return context
}

func blurred(_ radius: Double, _ draw: (CGContext) -> Void) -> CGImage {
    let context = canvas()
    draw(context)
    let image = CIImage(cgImage: context.makeImage()!)
    let soft = image.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: image.extent)
    return CIContext(options: [.workingColorSpace: space])
        .createCGImage(soft, from: image.extent, format: .RGBA8, colorSpace: space)!
}

func put(_ image: CGImage, on context: CGContext, down: CGFloat = 0) {
    context.saveGState()
    context.translateBy(x: 0, y: CGFloat(size) + down)
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    context.restoreGState()
}

func fill(_ path: CGPath, on context: CGContext, _ colours: [CGColor], _ stops: [CGFloat],
          from: CGPoint, to: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(CGGradient(colorsSpace: space, colors: colours as CFArray, locations: stops)!,
                               start: from, end: to,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

func outline(_ path: CGPath, _ width: CGFloat) -> CGPath {
    path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

/// Light or shade falling inside a shape from its own edge.
func inside(_ path: CGPath, on context: CGContext, _ tint: CGColor, x: CGFloat = 0, y: CGFloat, soft: Double) {
    let shade = blurred(soft) { c in
        c.setFillColor(tint)
        c.fill(CGRect(x: 0, y: 0, width: size, height: size))
        c.setBlendMode(.clear)
        c.translateBy(x: x, y: y)
        c.addPath(path)
        c.fillPath()
    }
    context.saveGState()
    context.addPath(path)
    context.clip()
    put(shade, on: context)
    context.restoreGState()
}

func over(_ path: CGPath, on context: CGContext, _ tint: CGColor, x: CGFloat = 0, y: CGFloat) {
    context.saveGState()
    context.translateBy(x: x, y: y)
    context.addPath(path)
    context.setFillColor(tint)
    context.fillPath()
    context.restoreGState()
}

// MARK: Shapes

let plate = CGPath(roundedRect: CGRect(x: 92, y: 92, width: 840, height: 840),
                   cornerWidth: 188, cornerHeight: 188, transform: nil)

/// The play button, with its corners rounded off.
let button: CGPath = {
    let path = CGMutablePath()
    path.addLines(between: [CGPoint(x: 344, y: 304), CGPoint(x: 344, y: 720), CGPoint(x: 704, y: 512)])
    path.closeSubpath()
    return path.union(outline(path, 190))
}()

/// Left of the middle, where a triangle's weight is.
let arrow: CGPath = {
    let line = CGMutablePath()
    line.move(to: CGPoint(x: 468, y: 394))
    line.addLine(to: CGPoint(x: 468, y: 626))
    line.move(to: CGPoint(x: 360, y: 522))
    line.addLine(to: CGPoint(x: 468, y: 630))
    line.addLine(to: CGPoint(x: 576, y: 522))
    return outline(line, 72).normalized(using: .winding)
}()

// MARK: The icon

let icon = canvas()

// The plate: lighter at the top, with a breath of the button's colours in two corners.
fill(plate, on: icon, [colour(surface0), colour(base)], [0, 1],
     from: CGPoint(x: 0, y: 92), to: CGPoint(x: 0, y: 932))
icon.saveGState()
icon.addPath(plate)
icon.clip()
put(blurred(100) { c in
    for (centre, radius, tint) in [(CGPoint(x: 300, y: 280), CGFloat(190), green),
                                   (CGPoint(x: 740, y: 780), CGFloat(210), teal)] {
        c.setFillColor(colour(tint, 0.13))
        c.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                 width: 2 * radius, height: 2 * radius))
    }
}, on: icon)
put(blurred(20) { $0.addPath(button); $0.setFillColor(colour(crust, 0.6)); $0.fillPath() }, on: icon, down: 16)
icon.restoreGState()

// Light along the plate's top edge, fading. Without it the plate is lost on a dark Dock.
fill(outline(CGPath(roundedRect: CGRect(x: 94.5, y: 94.5, width: 835, height: 835),
                    cornerWidth: 185.5, cornerHeight: 185.5, transform: nil), 5),
     on: icon, [colour(overlay), colour(surface2, 0.35), colour(surface1, 0.25)], [0, 0.45, 1],
     from: CGPoint(x: 0, y: 92), to: CGPoint(x: 0, y: 932))

// The button: lit from above, a little from below, and round its edge.
let edge = button.boundingBox
let tl = CGPoint(x: edge.minX, y: edge.minY), br = CGPoint(x: edge.maxX, y: edge.maxY)
fill(button, on: icon, [colour(green), colour(teal)], [0, 1], from: tl, to: br)
fill(button, on: icon, [colour(white, 0.20), colour(white, 0)], [0, 1], from: tl, to: CGPoint(x: tl.x, y: tl.y + 210))
fill(button, on: icon, [colour(white, 0), colour(white, 0.10)], [0, 1], from: CGPoint(x: 0, y: br.y - 120), to: CGPoint(x: 0, y: br.y))
icon.saveGState()
icon.addPath(button)
icon.clip()
put(blurred(6) { $0.addPath(outline(button, 12)); $0.setFillColor(colour(white, 0.5)); $0.fillPath() }, on: icon)
fill(outline(button, 7), on: icon, [colour(white, 0.9), colour(white, 0.11), colour(white, 0.5)], [0, 0.5, 1], from: tl, to: br)

// The arrow is raised, very softly: a pine shadow on the button, and a thread of light on top.
put(blurred(8) { $0.addPath(arrow); $0.setFillColor(colour(pine, 0.34)); $0.fillPath() }, on: icon, down: 8)
icon.restoreGState()
let box = arrow.boundingBox
fill(arrow, on: icon, [colour(0x2a2b3d), colour(base), colour(mantle)], [0, 0.6, 1],
     from: CGPoint(x: 0, y: box.minY), to: CGPoint(x: 0, y: box.maxY))
inside(arrow, on: icon, colour(subtext, 0.30), y: 3.5, soft: 2.5)

let path = CommandLine.arguments.dropFirst().first ?? "icon.png"
try! NSBitmapImageRep(cgImage: icon.makeImage()!).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: path))
