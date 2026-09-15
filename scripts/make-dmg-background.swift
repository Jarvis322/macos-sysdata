import AppKit

// Draws the disk image window's background at one scale: a quiet ground and
// an arrow from where the app sits to where Applications sits. The positions
// match scripts/dmg-settings.py; Finder draws the icons and their names.
//
//   swift scripts/make-dmg-background.swift <scale> <output.png>

let arguments = CommandLine.arguments
guard arguments.count == 3, let scale = Double(arguments[1]) else {
    FileHandle.standardError.write(Data("usage: make-dmg-background.swift <scale> <output.png>\n".utf8))
    exit(1)
}

let size = CGSize(width: 640, height: 400)
let pixels = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
pixels.size = size

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: pixels)

// The site's ground colour, so the download looks like it came from the page.
NSColor(srgbRed: 0.969, green: 0.965, blue: 0.953, alpha: 1).setFill()
CGRect(origin: .zero, size: size).fill()

// Icon centres are 180 pt from the top; AppKit counts from the bottom.
let centreY = size.height - 180
let arrow = NSBezierPath()
arrow.move(to: CGPoint(x: 262, y: centreY))
arrow.line(to: CGPoint(x: 372, y: centreY))
arrow.move(to: CGPoint(x: 356, y: centreY + 14))
arrow.line(to: CGPoint(x: 376, y: centreY))
arrow.line(to: CGPoint(x: 356, y: centreY - 14))
arrow.lineWidth = 3
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor(srgbRed: 0.72, green: 0.71, blue: 0.67, alpha: 1).setStroke()
arrow.stroke()

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let caption = NSAttributedString(
    string: "Drag to Applications to install",
    attributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 0.42, green: 0.41, blue: 0.38, alpha: 1),
        .paragraphStyle: paragraph,
    ]
)
// Above the icons, not under them: a Finder with the path bar or status bar
// switched on lays those over the bottom of the window.
caption.draw(in: CGRect(x: 0, y: size.height - 92, width: size.width, height: 22))

NSGraphicsContext.restoreGraphicsState()

guard let png = pixels.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: arguments[2]))
