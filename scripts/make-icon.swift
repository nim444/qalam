// Draws the app icon (assets/icon-1024.png): a pen writing a stroke, the same motif as the
// Android launcher icon. Run: swift scripts/make-icon.swift assets/icon-1024.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon-1024.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.translateBy(x: 0, y: size) // draw with y pointing down, like the Android vector
ctx.scaleBy(x: 1, y: -1)

// macOS icon grid: an 824-pt rounded square centred on the 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let colors = [CGColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1), CGColor(srgbRed: 0.04, green: 0.04, blue: 0.05, alpha: 1)]
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
ctx.restoreGState()
ctx.addPath(tilePath)
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.08))
ctx.setLineWidth(4)
ctx.strokePath()

// The Android art is on a 108-unit grid; scale it up and centre it a touch.
let k = size / 108
ctx.translateBy(x: 2 * k, y: -3 * k)
ctx.scaleBy(x: k, y: k)

let squiggle = CGMutablePath()
squiggle.move(to: CGPoint(x: 28, y: 77))
squiggle.addCurve(to: CGPoint(x: 42, y: 72), control1: CGPoint(x: 33, y: 66), control2: CGPoint(x: 37, y: 82))
ctx.addPath(squiggle)
ctx.setStrokeColor(CGColor(srgbRed: 0.31, green: 0.82, blue: 0.77, alpha: 1))
ctx.setLineWidth(4)
ctx.setLineCap(.round)
ctx.strokePath()

// The pen, drawn along its own axis from the tip, then turned 45° up and to the right.
ctx.saveGState()
ctx.translateBy(x: 41, y: 71)
ctx.rotate(by: -.pi / 4)
func fill(_ path: CGPath, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
    ctx.addPath(path)
    ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
    ctx.fillPath()
}
let nib = CGMutablePath()
nib.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 13, y: -4.6), CGPoint(x: 13, y: 4.6)])
nib.closeSubpath()
fill(nib, 0.81, 0.81, 0.83)
fill(CGPath(rect: CGRect(x: 12.8, y: -5.2, width: 3.7, height: 10.4), transform: nil), 0.31, 0.82, 0.77)
fill(CGPath(roundedRect: CGRect(x: 16.5, y: -5.2, width: 29.5, height: 10.4), cornerWidth: 1.2, cornerHeight: 1.2, transform: nil), 0.93, 0.93, 0.93)
fill(CGPath(roundedRect: CGRect(x: 45, y: -5.2, width: 6, height: 10.4), cornerWidth: 2.6, cornerHeight: 2.6, transform: nil), 0.74, 0.74, 0.76)
ctx.restoreGState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
