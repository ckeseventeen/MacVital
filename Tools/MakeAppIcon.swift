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

// Body gradient, drawn on the diagonal rather than straight down.
//
// It was three stops of the same blue lit from the top, which is the shape of
// every utility icon shipped since 2012 — legible, and completely anonymous.
// Travelling from azure into indigo gives the plate a hue to move through, and
// the diagonal keeps the light direction consistent with the highlight below.
NSGradient(colors: [
    NSColor(srgbRed: 0.42, green: 0.72, blue: 1.00, alpha: 1),
    NSColor(srgbRed: 0.20, green: 0.45, blue: 0.96, alpha: 1),
    NSColor(srgbRed: 0.16, green: 0.20, blue: 0.72, alpha: 1),
    NSColor(srgbRed: 0.10, green: 0.10, blue: 0.42, alpha: 1),
], atLocations: [0.0, 0.42, 0.78, 1.0], colorSpace: .sRGB)!.draw(in: plate, angle: -60)

// A light source, not a sweep. A linear wash brightens half the plate evenly
// and reads flat; a radial falloff placed off-centre is what makes a surface
// look curved.
// Radius deliberately larger than the plate: the falloff has to run off the
// edge. A radial that finishes inside the artwork draws its own boundary, and
// the first attempt put a visible crescent across the middle that read as a
// mistake rather than as light.
let lightCenter = CGPoint(x: plate.minX + plate.width * 0.26, y: plate.maxY - plate.height * 0.14)
NSGradient(
    starting: NSColor(white: 1, alpha: 0.30),
    ending: NSColor(white: 1, alpha: 0.0)
)!.draw(
    fromCenter: lightCenter, radius: 0,
    toCenter: lightCenter, radius: plate.width * 1.15,
    options: []
)

// Vignette opposite the light, so the far corner falls away instead of
// staying the same brightness as the middle.
// Same rule for the vignette: it starts well outside the centre so the two
// falloffs never meet at a visible line.
let shadeCenter = CGPoint(x: plate.maxX + plate.width * 0.10, y: plate.minY - plate.height * 0.10)
NSGradient(
    starting: NSColor(srgbRed: 0.02, green: 0.02, blue: 0.16, alpha: 0.32),
    ending: NSColor(srgbRed: 0.02, green: 0.02, blue: 0.16, alpha: 0.0)
)!.draw(
    fromCenter: shadeCenter, radius: plate.width * 0.05,
    toCenter: shadeCenter, radius: plate.width * 1.05,
    options: []
)

// Inner shadow around the whole edge: the plate reads as a solid object with
// thickness rather than a coloured sticker.
ctx.saveGState()
let outer = NSBezierPath(rect: plate.insetBy(dx: -80, dy: -80))
outer.append(platePath.reversed)
outer.windingRule = .evenOdd
ctx.setShadow(offset: .zero, blur: 26, color: NSColor(white: 0, alpha: 0.55).cgColor)
NSColor.black.setFill()
outer.fill()
ctx.restoreGState()

ctx.restoreGState()

// Rim light along the top edge fading into a dark lip at the bottom.
//
// Drawn as one gradient through the stroked band, not as two clipped halves.
// The halves left a visible step where they met — a hard horizontal seam on
// both edges at exactly the midpoint, which at 1024 looks like a rendering
// bug, because it is one.
ctx.saveGState()
platePath.addClip()

let rim = NSBezierPath(roundedRect: plate.insetBy(dx: 2, dy: 2), xRadius: radius - 2, yRadius: radius - 2)
ctx.addPath(rim.cgPath)
ctx.setLineWidth(4)
ctx.replacePathWithStrokedPath()
ctx.clip()

NSGradient(colors: [
    NSColor(white: 1, alpha: 0.42),
    NSColor(white: 1, alpha: 0.06),
    NSColor(srgbRed: 0.04, green: 0.04, blue: 0.24, alpha: 0.10),
    NSColor(srgbRed: 0.04, green: 0.04, blue: 0.24, alpha: 0.42),
], atLocations: [0.0, 0.42, 0.62, 1.0], colorSpace: .sRGB)!
    .draw(in: plate, angle: -90)

ctx.restoreGState()

// MARK: - Glyph

// Drawn from primitives, which is what the header has always claimed and what
// the code did not do — it reached for `internaldrive` and scaled it.
//
// A stock symbol is line art: uniform stroke, no thickness, no way to light it.
// On a coloured plate that reads as a pictogram *on* a surface rather than an
// object *sitting* on one, and no amount of work on the plate behind it fixes
// that. Solid faces with their own gradient can catch the same light as the
// plate, which is the whole difference between "flat" and "made of something".
//
// The silhouette is unchanged: a sloped lid over a slotted body, because the
// original reasoning still holds — a drive says "storage" at 16pt with no
// ambiguity, where a ring reads as a spinner and a wedge as a pie chart.

let bodyWidth: CGFloat = 470
let bodyHeight: CGFloat = 176
let lidHeight: CGFloat = 132
let lidTopWidth: CGFloat = 322
let centreX = side / 2
// Optically centred: the mass sits low, so geometric centring reads sunken.
let baseY = (side - (bodyHeight + lidHeight)) / 2 - 8

let bodyRect = NSRect(x: centreX - bodyWidth / 2, y: baseY, width: bodyWidth, height: bodyHeight)
let body = NSBezierPath(roundedRect: bodyRect, xRadius: 42, yRadius: 42)

// The lid: a trapezoid with its top corners rounded, sharing the body's width
// at the join.
let lidBottomY = bodyRect.maxY
let lidTopY = lidBottomY + lidHeight
let lid = NSBezierPath()
let corner: CGFloat = 40
lid.move(to: CGPoint(x: bodyRect.minX, y: lidBottomY))
lid.line(to: CGPoint(x: centreX - lidTopWidth / 2 - corner * 0.35, y: lidTopY - corner))
lid.curve(
    to: CGPoint(x: centreX - lidTopWidth / 2 + corner * 0.65, y: lidTopY),
    controlPoint1: CGPoint(x: centreX - lidTopWidth / 2 - corner * 0.1, y: lidTopY - corner * 0.35),
    controlPoint2: CGPoint(x: centreX - lidTopWidth / 2 + corner * 0.2, y: lidTopY)
)
lid.line(to: CGPoint(x: centreX + lidTopWidth / 2 - corner * 0.65, y: lidTopY))
lid.curve(
    to: CGPoint(x: centreX + lidTopWidth / 2 + corner * 0.35, y: lidTopY - corner),
    controlPoint1: CGPoint(x: centreX + lidTopWidth / 2 - corner * 0.2, y: lidTopY),
    controlPoint2: CGPoint(x: centreX + lidTopWidth / 2 + corner * 0.1, y: lidTopY - corner * 0.35)
)
lid.line(to: CGPoint(x: bodyRect.maxX, y: lidBottomY))
lid.close()

let silhouette = NSBezierPath()
silhouette.append(lid)
silhouette.append(body)
silhouette.windingRule = .nonZero

// One shadow for the whole object, cast onto the plate.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26,
              color: NSColor(white: 0, alpha: 0.38).cgColor)
NSColor.white.setFill()
silhouette.fill()
ctx.restoreGState()

// Lit from the same direction as the plate, so the object belongs to the
// scene: the lid catches the light, the body falls away from it.
ctx.saveGState()
silhouette.addClip()
NSGradient(colors: [
    NSColor(white: 1.00, alpha: 1),
    NSColor(white: 0.97, alpha: 1),
    NSColor(white: 0.84, alpha: 1),
], atLocations: [0.0, 0.55, 1.0], colorSpace: .sRGB)!
    .draw(in: NSRect(x: bodyRect.minX, y: baseY, width: bodyWidth, height: bodyHeight + lidHeight), angle: -70)
ctx.restoreGState()

// The seam between lid and body, cut in plate colour rather than drawn in
// grey — it is a gap in the object, not a line on it.
let seam = NSBezierPath(
    roundedRect: NSRect(x: bodyRect.minX + 10, y: lidBottomY - 9, width: bodyWidth - 20, height: 11),
    xRadius: 5, yRadius: 5
)
// Darker than the plate rather than the same blue: a gap sees shadow, not
// the surface behind the object.
NSColor(srgbRed: 0.10, green: 0.20, blue: 0.62, alpha: 1).setFill()
seam.fill()

// Slots, same treatment.
// Slots inherit the seam's fill colour, set just above.
let slotCount = 6
let slotWidth: CGFloat = 22
let slotHeight: CGFloat = 62
let slotGap: CGFloat = 20
let slotsWidth = CGFloat(slotCount) * slotWidth + CGFloat(slotCount - 1) * slotGap
var slotX = centreX - slotsWidth / 2
let slotY = bodyRect.minY + (bodyHeight - slotHeight) / 2 - 4
for _ in 0..<slotCount {
    NSBezierPath(
        roundedRect: NSRect(x: slotX, y: slotY, width: slotWidth, height: slotHeight),
        xRadius: 11, yRadius: 11
    ).fill()
    slotX += slotWidth + slotGap
}

// A hairline of the plate's own light along the very top of the lid: the edge
// facing the light source is the one that should be brightest.
ctx.saveGState()
silhouette.addClip()
NSGradient(
    starting: NSColor(white: 1, alpha: 0.9),
    ending: NSColor(white: 1, alpha: 0)
)!.draw(in: NSRect(x: bodyRect.minX, y: lidTopY - 26, width: bodyWidth, height: 26), angle: -90)
ctx.restoreGState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(3) }

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
