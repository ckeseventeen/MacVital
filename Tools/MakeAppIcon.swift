import AppKit

// MacVital app icon.
//
// The glyph is a storage disc seen head-on with a wedge cleared out of it —
// the app measures space and gives some back, and a ring reads at 16pt where
// a detailed drive silhouette turns to mush. Built from primitives rather than
// an SF Symbol so the proportions can be tuned for the icon grid.

let side: CGFloat = 1024

// An explicit 1x bitmap rep, not `NSImage.lockFocus()` — the latter adopts the
// main display's backing scale and silently yields a 2048px file on Retina.
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(side), pixelsHigh: Int(side),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { exit(1) }
rep.size = NSSize(width: side, height: side)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
defer { NSGraphicsContext.restoreGraphicsState() }

guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

// macOS icon grid: the art sits in an 824pt rounded rect inside a 1024 canvas.
let inset: CGFloat = 100
let radius: CGFloat = 190
let plate = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
let platePath = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

// Ambient shadow under the plate, the standard macOS icon lift.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30,
              color: NSColor(white: 0, alpha: 0.28).cgColor)
NSColor.black.setFill()
platePath.fill()
ctx.restoreGState()

ctx.saveGState()
platePath.addClip()

// Body gradient, lit from the top.
NSGradient(colors: [
    NSColor(srgbRed: 0.40, green: 0.66, blue: 1.00, alpha: 1),
    NSColor(srgbRed: 0.16, green: 0.38, blue: 0.93, alpha: 1),
    NSColor(srgbRed: 0.08, green: 0.17, blue: 0.60, alpha: 1),
], atLocations: [0.0, 0.52, 1.0], colorSpace: .sRGB)!.draw(in: plate, angle: -90)

// Broad specular sweep across the upper half.
NSGradient(
    starting: NSColor(white: 1, alpha: 0.30),
    ending: NSColor(white: 1, alpha: 0.0)
)!.draw(
    in: NSRect(x: plate.minX, y: plate.midY - 40, width: plate.width, height: plate.height / 2 + 40),
    angle: -90
)
ctx.restoreGState()

// MARK: - Glyph

// The same drive the app shows on its own welcome screen. A ring or a wedge
// would be more decorative but reads as a spinner or a pie chart; the drive
// says "storage" at 16pt with no ambiguity, which is the whole job.
let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .regular)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
guard let symbol = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) else { exit(2) }

let glyphSize = symbol.size
let target: CGFloat = 496
let scale = min(target / glyphSize.width, target / glyphSize.height)
let drawn = NSSize(width: glyphSize.width * scale, height: glyphSize.height * scale)
// Nudged up: the drive glyph is bottom-heavy, so geometric centring reads low.
let glyphRect = NSRect(
    x: (side - drawn.width) / 2,
    y: (side - drawn.height) / 2 + 14,
    width: drawn.width,
    height: drawn.height
)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -7), blur: 22,
              color: NSColor(white: 0, alpha: 0.34).cgColor)
symbol.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1)
ctx.restoreGState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(3) }

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
