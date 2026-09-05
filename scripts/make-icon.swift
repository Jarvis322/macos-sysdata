// Draws the app icon at 1024x1024 and writes it as PNG.
// Usage: swift scripts/make-icon.swift <output.png>
//
// Composition (back to front):
//   background  deep slate squircle with a soft top light and a drop shadow
//   midground   two slate storage bars, the top one breaking apart into
//               blocks that fade out (System Data being released)
//   foreground  one emerald bar with a glow (space given back)

import AppKit
import CoreGraphics
import UniformTypeIdentifiers

let outputPath = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"
let canvas = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

guard let context = CGContext(
    data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("could not create bitmap context")
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

/// Apple-style continuous-corner shape (superellipse, exponent 5).
func squircle(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 1440
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / 5)
        let y = rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / 5)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func linearGradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: stops.map(\.0) as CFArray, locations: stops.map(\.1))!
}

func fillBar(_ rect: CGRect, top: CGColor, bottom: CGColor, glow: CGColor? = nil, alpha: CGFloat = 1) {
    let path = CGPath(roundedRect: rect, cornerWidth: rect.height * 0.32, cornerHeight: rect.height * 0.32, transform: nil)
    context.saveGState()
    context.setAlpha(alpha)
    if let glow {
        context.setShadow(offset: .zero, blur: 46, color: glow)
        context.addPath(path)
        context.setFillColor(bottom)
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
    }
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(
        linearGradient([(top, 0), (bottom, 1)]),
        start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: []
    )
    // Thin highlight along the top edge gives the bar a lit, rounded surface.
    context.setStrokeColor(color(0xFFFFFF, 0.16))
    context.setLineWidth(4)
    context.move(to: CGPoint(x: rect.minX + rect.height * 0.3, y: rect.maxY - 2))
    context.addLine(to: CGPoint(x: rect.maxX - rect.height * 0.3, y: rect.maxY - 2))
    context.strokePath()
    context.restoreGState()
}

// MARK: Background

let shapeRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = squircle(in: shapeRect)

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: color(0x000000, 0.38))
context.addPath(shape)
context.setFillColor(color(0x12151C))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(shape)
context.clip()
context.drawLinearGradient(
    linearGradient([(color(0x2B303C), 0), (color(0x181C25), 0.55), (color(0x0C0F15), 1)]),
    start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: []
)
// Soft light from the top so the surface does not read as flat black.
context.drawRadialGradient(
    linearGradient([(color(0xFFFFFF, 0.10), 0), (color(0xFFFFFF, 0), 1)]),
    startCenter: CGPoint(x: 512, y: 980), startRadius: 0,
    endCenter: CGPoint(x: 512, y: 980), endRadius: 720, options: []
)
context.restoreGState()

// 1px inner edge highlight.
context.saveGState()
context.addPath(squircle(in: shapeRect.insetBy(dx: 2, dy: 2)))
context.setStrokeColor(color(0xFFFFFF, 0.09))
context.setLineWidth(3)
context.strokePath()
context.restoreGState()

// MARK: Bars

let barX: CGFloat = 272
let barWidth: CGFloat = 480
let barHeight: CGFloat = 96
let gap: CGFloat = 40
let bottomY: CGFloat = 512 - (3 * barHeight + 2 * gap) / 2

let slateTop = color(0x525A6B)
let slateBottom = color(0x333947)

// Top bar: shortened, its right end dissolving into blocks.
let topY = bottomY + 2 * (barHeight + gap)
fillBar(CGRect(x: barX, y: topY, width: 318, height: barHeight), top: slateTop, bottom: slateBottom)
let blocks: [(x: CGFloat, size: CGFloat, alpha: CGFloat)] = [
    (620, 60, 0.80), (700, 48, 0.50), (768, 36, 0.28), (822, 26, 0.14),
]
for block in blocks {
    let rect = CGRect(x: block.x, y: topY + (barHeight - block.size) / 2, width: block.size, height: block.size)
    fillBar(rect, top: slateTop, bottom: slateBottom, alpha: block.alpha)
}

// Middle bar: full width.
fillBar(CGRect(x: barX, y: bottomY + barHeight + gap, width: barWidth, height: barHeight), top: slateTop, bottom: slateBottom)

// Bottom bar: emerald, glowing. This is the space that came back.
fillBar(
    CGRect(x: barX, y: bottomY, width: barWidth, height: barHeight),
    top: color(0x3CE58F), bottom: color(0x12B36A), glow: color(0x22D37E, 0.55)
)

// MARK: Write

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
          URL(fileURLWithPath: outputPath) as CFURL, UTType.png.identifier as CFString, 1, nil
      ) else {
    fatalError("could not create image destination")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(outputPath)") }
print("wrote \(outputPath)")
