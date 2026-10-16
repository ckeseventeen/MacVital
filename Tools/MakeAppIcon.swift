import AppKit

// PureMark (净迹) app icon generator.
//
// The glyph is the name: a brush-stroke tick — the *mark* — with a four-point
// sparkle beside it for *pure*. Two flat shapes, nothing else. That is the
// whole brief for a macOS icon since Liquid Glass: the system supplies the
// depth, the specular rim and the dark/tinted/clear variants, so the artwork's
// only job is a silhouette that still reads at 16pt.
//
// Writes two things from the same geometry:
//
// 1. `AppIcon.icon` — an Icon Composer document (layer PNGs + icon.json).
//    macOS 26 and later render this themselves, glass and all.
//    actool also renders it down to the AppIcon.icns and legacy renditions
//    that macOS 14/15 read, so the deployment range is covered from this.
// 2. `AppIcon.appiconset/icon_1024.png` — a flat render on the classic 824pt
//    plate, only for Xcode 15/16, which do not know `.icon` and skip it.
//    Xcode 26 and later ignore the appiconset once the `.icon` is present.
//    `make icon` downsamples it to the remaining sizes.
//
// Run from the repository root: `make icon`.

let side: CGFloat = 1024
let resources = "Sources/MacVital/Resources"
let iconDocument = "\(resources)/AppIcon.icon"
let legacyIcon = "\(resources)/Assets.xcassets/AppIcon.appiconset/icon_1024.png"

// MARK: - Palette

// Brand blue, bracketing the AccentColor asset (0.216, 0.541, 0.867) so the
// icon and the app's controls read as the same colour.
let fillTop = (r: 0.38, g: 0.66, b: 0.99)
let fillBottom = (r: 0.13, g: 0.40, b: 0.85)
let darkFillTop = (r: 0.20, g: 0.21, b: 0.24)
let darkFillBottom = (r: 0.09, g: 0.09, b: 0.11)
// Dark mode keeps the brand on the glyph instead of the plate, as the system
// apps do — the AccentColor asset's own dark value.
let darkGlyph = (r: 0.298, g: 0.608, b: 0.922)

// MARK: - Geometry (1024 canvas, y down)

struct Cubic {
    var p0, c1, c2, p1: CGPoint

    func point(_ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p1.x,
                       y: a * p0.y + b * c1.y + c * c2.y + d * p1.y)
    }

}

// The tick: a short left arm into the valley, a long right arm out to a fine
// point, like a brush lifted at the end of the stroke.
let tickArms = [
    Cubic(p0: CGPoint(x: 274, y: 552), c1: CGPoint(x: 330, y: 596),
          c2: CGPoint(x: 382, y: 680), p1: CGPoint(x: 452, y: 724)),
    Cubic(p0: CGPoint(x: 452, y: 724), c1: CGPoint(x: 526, y: 770),
          c2: CGPoint(x: 658, y: 568), p1: CGPoint(x: 792, y: 312)),
]
// Share of the stroke's parameter spent on the left arm; the width peaks here.
let valley: CGFloat = 0.3

func smoothstep(_ x: CGFloat) -> CGFloat {
    let t = min(max(x, 0), 1)
    return t * t * (3 - 2 * t)
}

/// Stroke width along the whole tick, s in 0...1.
func tickWidth(_ s: CGFloat) -> CGFloat {
    let start: CGFloat = 58, peak: CGFloat = 118, tip: CGFloat = 22
    if s <= valley { return start + (peak - start) * smoothstep(s / valley) }
    return peak - (peak - tip) * pow(smoothstep((s - valley) / (1 - valley)), 1.15)
}

/// The tick as a run of overlapping discs along the centreline. An offset
/// outline would be cheaper, but its inner edge folds over itself in the
/// valley, where the bend is tighter than half the stroke width, and the fold
/// punches a notch out of the fill. Discs have no inside edge to fold, and
/// they give round caps for free.
func tickPath() -> CGPath {
    let path = CGMutablePath()
    let samples = 900
    for (index, arm) in tickArms.enumerated() {
        let span: (CGFloat, CGFloat) = index == 0 ? (0, valley) : (valley, 1)
        let count = index == 0 ? Int(CGFloat(samples) * valley) : Int(CGFloat(samples) * (1 - valley))
        for i in 0...count {
            let t = CGFloat(i) / CGFloat(count)
            let p = arm.point(t)
            let r = tickWidth(span.0 + (span.1 - span.0) * t) / 2
            path.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
    }
    return path
}

// The sparkle: four points joined by concave curves, the shape macOS itself
// uses for "magic" — instantly read as clean without drawing a broom.
func sparklePath() -> CGPath {
    let c = CGPoint(x: 330, y: 326)
    let radius: CGFloat = 112, pinch: CGFloat = 0.13
    let tips = [CGPoint(x: c.x, y: c.y - radius), CGPoint(x: c.x + radius, y: c.y),
                CGPoint(x: c.x, y: c.y + radius), CGPoint(x: c.x - radius, y: c.y)]
    let path = CGMutablePath()
    path.move(to: tips[0])
    for i in 0..<4 {
        let a = tips[i], b = tips[(i + 1) % 4]
        let control = CGPoint(x: c.x + (a.x - c.x + b.x - c.x) * pinch,
                              y: c.y + (a.y - c.y + b.y - c.y) * pinch)
        path.addQuadCurve(to: b, control: control)
    }
    path.closeSubpath()
    return path
}

// MARK: - Rendering

func render(_ draw: (CGContext) -> Void) -> Data {
    // An explicit 1x bitmap rep, not `NSImage.lockFocus()` — the latter adopts
    // the main display's backing scale and silently yields a 2048px file.
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: rep) else { fail("no bitmap context") }
    rep.size = NSSize(width: side, height: side)
    let ctx = graphics.cgContext
    ctx.setShouldAntialias(true)
    // Work in the same y-down space as the geometry above.
    ctx.translateBy(x: 0, y: side)
    ctx.scaleBy(x: 1, y: -1)
    draw(ctx)
    graphics.flushGraphics()
    guard let png = rep.representation(using: .png, properties: [:]) else { fail("PNG encoding failed") }
    return png
}

func srgb(_ c: (r: Double, g: Double, b: Double), _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: alpha)
}

func glyphLayer(_ path: CGPath) -> Data {
    render { ctx in
        ctx.addPath(path)
        ctx.setFillColor(.white)
        ctx.fillPath()
    }
}

/// Apple's continuous-corner plate, approximated by a superellipse — the
/// circular-arc corners of `roundedRect` visibly kink against every other
/// icon in the Dock.
func platePath(in rect: CGRect) -> CGPath {
    let n: CGFloat = 5.2, steps = 720
    let path = CGMutablePath()
    for i in 0..<steps {
        let theta = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let cx = cos(theta), sy = sin(theta)
        let x = pow(abs(cx), 2 / n) * (cx < 0 ? -1 : 1)
        let y = pow(abs(sy), 2 / n) * (sy < 0 ? -1 : 1)
        let p = CGPoint(x: rect.midX + x * rect.width / 2, y: rect.midY + y * rect.height / 2)
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

func legacyRender() -> Data {
    render { ctx in
        // macOS 11–15 grid: an 824pt plate centred in the 1024 canvas.
        let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = platePath(in: plate)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!

        // Drop shadow. y-down space, so a positive offset falls downward.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 24,
                      color: CGColor(gray: 0, alpha: 0.30))
        ctx.addPath(shape)
        ctx.setFillColor(srgb(fillBottom))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        let body = CGGradient(colorsSpace: space,
                              colors: [srgb(fillTop), srgb(fillBottom)] as CFArray,
                              locations: [0, 1])!
        ctx.drawLinearGradient(body, start: CGPoint(x: 512, y: plate.minY),
                               end: CGPoint(x: 512, y: plate.maxY), options: [])

        // A soft glow from the upper edge — the light Liquid Glass would add.
        let glow = CGGradient(colorsSpace: space,
                              colors: [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0)] as CFArray,
                              locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: plate.minY - 120), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: plate.minY - 120), endRadius: 760, options: [])

        // Glyphs, scaled from the full-bleed .icon canvas onto the plate.
        let scale = plate.width / side
        ctx.translateBy(x: plate.minX, y: plate.minY)
        ctx.scaleBy(x: scale, y: scale)
        ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28,
                      color: srgb((r: 0.02, g: 0.14, b: 0.42), 0.35))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        for glyph in [tickPath(), sparklePath()] {
            ctx.addPath(glyph)
        }
        ctx.setFillColor(.white)
        ctx.fillPath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        // Hairline rim, brighter at the top, so the plate holds its edge on a
        // dark Dock the way system icons do.
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.setLineWidth(3)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let rim = CGGradient(colorsSpace: space,
                             colors: [CGColor(gray: 1, alpha: 0.45), CGColor(gray: 1, alpha: 0.08)] as CFArray,
                             locations: [0, 1])!
        ctx.drawLinearGradient(rim, start: CGPoint(x: 512, y: plate.minY),
                               end: CGPoint(x: 512, y: plate.maxY), options: [])
        ctx.restoreGState()
    }
}

// MARK: - Icon Composer document

func colorString(_ c: (r: Double, g: Double, b: Double)) -> String {
    String(format: "srgb:%.5f,%.5f,%.5f,1.00000", c.r, c.g, c.b)
}

func verticalGradient(_ top: (r: Double, g: Double, b: Double),
                      _ bottom: (r: Double, g: Double, b: Double)) -> [String: Any] {
    [
        "linear-gradient": [colorString(top), colorString(bottom)],
        "orientation": ["start": ["x": 0.5, "y": 0], "stop": ["x": 0.5, "y": 1]],
    ]
}

func glassLayer(_ name: String) -> [String: Any] {
    [
        "glass": true,
        "image-name": "\(name).png",
        "name": name,
        "fill-specializations": [
            ["appearance": "dark", "value": ["automatic-gradient": colorString(darkGlyph)]],
        ],
    ]
}

let iconJSON: [String: Any] = [
    "fill-specializations": [
        ["value": verticalGradient(fillTop, fillBottom)],
        ["appearance": "dark", "value": verticalGradient(darkFillTop, darkFillBottom)],
    ],
    "groups": [
        [
            "layers": [glassLayer("sparkle"), glassLayer("tick")],
            "shadow": ["kind": "neutral", "opacity": 0.5],
            "translucency": ["enabled": true, "value": 0.4],
        ],
    ],
    "supported-platforms": ["circles": ["watchOS"], "squares": "shared"],
]

// MARK: - Output

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("MakeAppIcon: \(message)\n".utf8))
    exit(1)
}

func write(_ data: Data, to path: String) {
    do {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    } catch {
        fail("could not write \(path): \(error)")
    }
}

guard FileManager.default.fileExists(atPath: resources) else {
    fail("run from the repository root (no \(resources) here)")
}

write(glyphLayer(tickPath()), to: "\(iconDocument)/Assets/tick.png")
write(glyphLayer(sparklePath()), to: "\(iconDocument)/Assets/sparkle.png")
do {
    let json = try JSONSerialization.data(withJSONObject: iconJSON, options: [.prettyPrinted, .sortedKeys])
    write(json + Data("\n".utf8), to: "\(iconDocument)/icon.json")
} catch {
    fail("icon.json: \(error)")
}
write(legacyRender(), to: legacyIcon)
