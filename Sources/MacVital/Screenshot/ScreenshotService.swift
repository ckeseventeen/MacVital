import AppKit

/// Screen capture, delegated to `/usr/sbin/screencapture`.
///
/// Not `ScreenCaptureKit`: the system binary already provides the native
/// crosshair selection UI, the window picker, the shutter sound and the
/// Screen Recording permission prompt. Reimplementing the selection overlay
/// would be a worse version of something every Mac user already knows, and the
/// app is not sandboxed, so spawning it is available to us.
@MainActor
final class ScreenshotService: ObservableObject {

    enum Mode: String, CaseIterable, Identifiable {
        case region
        case fullScreen
        case window

        var id: String { rawValue }

        var title: String {
            switch self {
            case .region: return "选区"
            case .fullScreen: return "全屏"
            case .window: return "窗口"
            }
        }

        var symbolName: String {
            switch self {
            case .region: return "crop"
            case .fullScreen: return "rectangle.dashed"
            case .window: return "macwindow"
            }
        }

        var detail: String {
            switch self {
            case .region: return "拖动选择一块区域"
            case .fullScreen: return "捕获整个屏幕"
            case .window: return "点击选择一个窗口"
            }
        }

        /// Flags for `screencapture`. `-x` silences the shutter for the
        /// non-interactive mode only; the interactive ones keep it, because the
        /// sound is the feedback that the capture actually happened.
        var arguments: [String] {
            switch self {
            case .region: return ["-i"]
            case .fullScreen: return ["-x"]
            case .window: return ["-i", "-W"]
            }
        }

        /// Whether our own window would end up in the shot.
        var capturesOurWindow: Bool { self == .fullScreen }
    }

    struct Capture: Equatable {
        var url: URL
        var image: NSImage
        var size: CGSize
        var takenAt: Date
    }

    @Published private(set) var latest: Capture?
    @Published private(set) var isCapturing = false
    @Published var errorMessage: String?
    @Published var delaySeconds: Int = 0

    private let scratch: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("MacVital-Screenshots", isDirectory: true)

    // MARK: - Capture

    func capture(mode: Mode, hiding window: NSWindow?) async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }

        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let destination = scratch.appendingPathComponent("\(UUID().uuidString).png")

        // Our own window is in front of everything the user wants to capture.
        // Hide it for full-screen shots and put it back afterwards; the
        // interactive modes let the user pick around it, so leave those alone.
        let shouldHide = mode.capturesOurWindow && window != nil
        if shouldHide {
            window?.orderOut(nil)
            // One runloop turn is not enough — the window server needs a beat
            // to actually stop compositing it.
            try? await Task.sleep(for: .milliseconds(220))
        }

        var arguments = mode.arguments
        if delaySeconds > 0 { arguments += ["-T", String(delaySeconds)] }
        arguments.append(destination.path)

        let status = await run(arguments: arguments)

        if shouldHide {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        // Escape during an interactive capture exits cleanly and writes
        // nothing. That is a cancellation, not a failure — say nothing.
        guard FileManager.default.fileExists(atPath: destination.path) else {
            if status != 0 && status != 1 {
                errorMessage = "截图失败（screencapture 退出码 \(status)）。"
            }
            return
        }

        guard let image = NSImage(contentsOf: destination) else {
            errorMessage = "截图已保存但无法读取。"
            return
        }

        latest = Capture(
            url: destination,
            image: image,
            size: Self.pixelSize(of: image) ?? image.size,
            takenAt: Date()
        )
    }

    private func run(arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = arguments
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: -1)
            }
        }
    }

    /// `NSImage.size` is in points; the file is in pixels. On Retina those
    /// differ by 2x and reporting the point size makes a 2560-wide shot look
    /// like 1280.
    private static func pixelSize(of image: NSImage) -> CGSize? {
        guard let rep = image.representations.first as? NSBitmapImageRep else { return nil }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    // MARK: - Actions on the latest capture

    func copyToPasteboard() {
        guard let latest else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([latest.image])
    }

    /// Save into the user's Desktop with a Finder-style timestamped name.
    ///
    /// `image` is the flattened capture-plus-annotations when the editor has
    /// any; passing nil copies the original file untouched.
    @discardableResult
    func saveToDesktop(image: NSImage? = nil) -> URL? {
        guard let latest else { return nil }
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            errorMessage = "找不到桌面目录。"
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        var target = desktop.appendingPathComponent("截屏 \(formatter.string(from: latest.takenAt)).png")

        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = desktop.appendingPathComponent("截屏 \(formatter.string(from: latest.takenAt)) (\(counter)).png")
            counter += 1
        }

        do {
            if let image {
                guard let data = Self.pngData(from: image) else {
                    errorMessage = "无法编码标注后的图片。"
                    return nil
                }
                try data.write(to: target, options: .atomic)
            } else {
                try FileManager.default.copyItem(at: latest.url, to: target)
            }
            return target
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
            return nil
        }
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let rep = image.representations.first as? NSBitmapImageRep else {
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
            return bitmap.representation(using: .png, properties: [:])
        }
        return rep.representation(using: .png, properties: [:])
    }

    func revealLatest() {
        guard let latest else { return }
        NSWorkspace.shared.activateFileViewerSelecting([latest.url])
    }

    func discard() {
        if let latest { try? FileManager.default.removeItem(at: latest.url) }
        latest = nil
    }
}
