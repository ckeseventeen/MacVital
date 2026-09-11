import AppKit

// PureMark (净迹) app icon generator.
//
// Generates the macOS 1024x1024 application icon conforming to Apple's Human Interface Guidelines.
// Loads the master asset Tools/PureMark-Master.jpg, crops the central squircle plate,
// maps it into the standard 824pt squircle with rounded corners (r=185pt) and renders ambient macOS drop shadow.

let side: CGFloat = 1024

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
let radius: CGFloat = 185
let plate = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
let platePath = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

// Ambient shadow under the plate: standard macOS icon lift.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 32,
              color: NSColor(white: 0, alpha: 0.32).cgColor)
NSColor.black.setFill()
platePath.fill()
ctx.restoreGState()

// Secondary contact shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 12,
              color: NSColor(white: 0, alpha: 0.22).cgColor)
NSColor.black.setFill()
platePath.fill()
ctx.restoreGState()

// Clip to squircle plate
ctx.saveGState()
platePath.addClip()

let invocationPath = CommandLine.arguments[0]
let scriptURL = URL(fileURLWithPath: invocationPath).deletingLastPathComponent()
let masterCandidates = [
    scriptURL.appendingPathComponent("PureMark-Master.jpg"),
    URL(fileURLWithPath: "Tools/PureMark-Master.jpg")
]

var masterData: Data?
for url in masterCandidates {
    if let data = try? Data(contentsOf: url) {
        masterData = data
        break
    }
}

if let data = masterData,
   let sourceRep = NSBitmapImageRep(data: data),
   let sourceCG = sourceRep.cgImage {
    let srcW = CGFloat(sourceCG.width)
    let srcH = CGFloat(sourceCG.height)
    let cropRect = CGRect(x: srcW * (128.0 / 1024.0),
                          y: srcH * (128.0 / 1024.0),
                          width: srcW * (768.0 / 1024.0),
                          height: srcH * (768.0 / 1024.0))
    if let croppedCG = sourceCG.cropping(to: cropRect) {
        ctx.draw(croppedCG, in: plate)
    }
}
ctx.restoreGState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(3) }

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Sources/MacVital/Resources/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
do {
    try png.write(to: URL(fileURLWithPath: out))
} catch {
    let message = "could not write \(out): \(error)\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(4)
}
print("wrote \(out)")
