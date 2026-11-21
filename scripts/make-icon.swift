// Renders the 1024×1024 app icon: a sun shining down on a leaf.
// Usage: swift scripts/make-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png")

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
// App Store icons must be opaque: no alpha channel.
let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// Flip so y grows downward, like a design tool.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)
let s = CGFloat(size)

// Background: night-green at the bottom, lighter towards the sun.
let bg = CGGradient(colorsSpace: space, colors: [rgb(0x1E6B47), rgb(0x0B2E22)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: s / 2, y: 0), end: CGPoint(x: s / 2, y: s), options: [])

let sun = CGPoint(x: s / 2, y: s * 0.27)

// Light falling from the sun: a soft cone.
ctx.saveGState()
ctx.beginPath()
ctx.move(to: sun)
ctx.addLine(to: CGPoint(x: s * 0.08, y: s))
ctx.addLine(to: CGPoint(x: s * 0.92, y: s))
ctx.closePath()
ctx.clip()
let beam = CGGradient(
    colorsSpace: space, colors: [rgb(0xFFE08A, 0.55), rgb(0xFFE08A, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(beam, start: sun, end: CGPoint(x: s / 2, y: s * 0.95), options: [])
ctx.restoreGState()

// Sun glow, then disc.
let glow = CGGradient(
    colorsSpace: space, colors: [rgb(0xFFD166, 0.6), rgb(0xFFD166, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: sun, startRadius: 0, endCenter: sun, endRadius: s * 0.26, options: [])
ctx.setFillColor(rgb(0xFFD166))
ctx.fillEllipse(in: CGRect(x: sun.x - s * 0.12, y: sun.y - s * 0.12, width: s * 0.24, height: s * 0.24))

// Leaf: two arcs meeting at the tip and the stem, tilted slightly.
ctx.saveGState()
ctx.translateBy(x: s / 2, y: s * 0.70)
ctx.rotate(by: -.pi / 9)
let tip = CGPoint(x: 0, y: -s * 0.22)
let base = CGPoint(x: 0, y: s * 0.20)
let leaf = CGMutablePath()
leaf.move(to: base)
leaf.addCurve(to: tip, control1: CGPoint(x: -s * 0.28, y: s * 0.06), control2: CGPoint(x: -s * 0.16, y: -s * 0.17))
leaf.addCurve(to: base, control1: CGPoint(x: s * 0.16, y: -s * 0.17), control2: CGPoint(x: s * 0.28, y: s * 0.06))
ctx.addPath(leaf)
ctx.clip()
let leafFill = CGGradient(colorsSpace: space, colors: [rgb(0xB8F06A), rgb(0x4CAF50)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(leafFill, start: tip, end: base, options: [])
// Midrib and veins.
ctx.setStrokeColor(rgb(0x2E7D32, 0.8))
ctx.setLineCap(.round)
ctx.setLineWidth(s * 0.014)
ctx.move(to: CGPoint(x: 0, y: s * 0.20))
ctx.addLine(to: CGPoint(x: 0, y: -s * 0.18))
ctx.strokePath()
ctx.setLineWidth(s * 0.008)
for y in stride(from: -0.10, through: 0.10, by: 0.07) {
    for side in [-1.0, 1.0] {
        ctx.move(to: CGPoint(x: 0, y: s * (y + 0.05)))
        ctx.addLine(to: CGPoint(x: s * 0.12 * side, y: s * (y - 0.04)))
    }
}
ctx.strokePath()
ctx.restoreGState()

// Stem.
ctx.setStrokeColor(rgb(0x4CAF50))
ctx.setLineCap(.round)
ctx.setLineWidth(s * 0.022)
let stemTop = CGPoint(x: s / 2 + s * 0.20 * sin(.pi / 9), y: s * 0.70 + s * 0.20 * cos(.pi / 9))
ctx.move(to: stemTop)
ctx.addQuadCurve(to: CGPoint(x: s * 0.60, y: s * 0.98), control: CGPoint(x: s * 0.57, y: s * 0.92))
ctx.strokePath()

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(out.path)") }
print("wrote \(out.path)")
