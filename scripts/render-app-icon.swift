// Copyright 2026 the Sommelier project. SPDX-License-Identifier: GPL-3.0-or-later
// Renders the app icon (the drop) into App/Sommelier/Assets.xcassets/AppIcon.appiconset.
// Usage: swiftc -O scripts/render-app-icon.swift -o /tmp/render-icon && /tmp/render-icon App/Sommelier/Assets.xcassets/AppIcon.appiconset
import AppKit
import CoreGraphics

// Sommelier app icon: Apple's macOS grid (the squircle fills 824/1024 of the canvas), a wine gradient, the drop in white.
func drop(scale s: CGFloat, offset o: CGPoint) -> CGPath {
    let p = CGMutablePath()
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }
    p.move(to: pt(50, 8))
    p.addCurve(to: pt(80, 64), control1: pt(53, 12), control2: pt(80, 42))
    p.addArc(center: pt(50, 64), radius: 30 * s, startAngle: 0, endAngle: .pi, clockwise: false)
    p.addCurve(to: pt(50, 8), control1: pt(20, 42), control2: pt(47, 12))
    p.closeSubpath()
    p.move(to: pt(42, 50)); p.addLine(to: pt(42, 78)); p.addLine(to: pt(66, 64)); p.closeSubpath()
    return p
}

func render(size: Int) -> Data {
    let S = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)            // SVG-style, y down
    let inset = S * 100 / 1024, side = S - 2 * inset, r = side * 0.2237
    let square = CGRect(x: inset, y: inset, width: side, height: side)
    let shape = CGPath(roundedRect: square, cornerWidth: r, cornerHeight: r, transform: nil)
    // Shadow under the squircle, as Apple's template has.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: S * 0.012), blur: S * 0.03, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
    ctx.addPath(shape); ctx.setFillColor(CGColor(red: 0.36, green: 0.07, blue: 0.16, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(shape); ctx.clip()
    let colors = [CGColor(red: 0.66, green: 0.19, blue: 0.32, alpha: 1), CGColor(red: 0.36, green: 0.07, blue: 0.16, alpha: 1), CGColor(red: 0.21, green: 0.035, blue: 0.10, alpha: 1)] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 0.58, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: inset, y: inset), end: CGPoint(x: inset + side, y: inset + side), options: [])
    // A soft light from the top, the way Apple's icons catch it.
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.18), CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: inset + side * 0.5, y: inset), startRadius: 0, endCenter: CGPoint(x: inset + side * 0.5, y: inset), endRadius: side * 0.9, options: [])
    ctx.restoreGState()
    // The drop, 72% of the square, centred.
    let scale = side * 0.72 / 100
    let origin = CGPoint(x: inset + (side - 100 * scale) / 2, y: inset + (side - 100 * scale) / 2 + side * 0.01)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: S * 0.008), blur: S * 0.02, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.25))
    ctx.addPath(drop(scale: scale, offset: origin)); ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments[1]
for (name, size) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try! render(size: size).write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("done")
