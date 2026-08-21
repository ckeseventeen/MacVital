import AVFoundation
import AppKit
import ScreenCaptureKit

/// Screen recording via ScreenCaptureKit, written straight to H.264.
///
/// `screencapture` cannot record, so this is the one capture path that had to
/// be built rather than delegated. The stream delivers `CMSampleBuffer`s that
/// go directly into an `AVAssetWriter` — no intermediate images, no frame
/// queue of our own to get wrong.
@MainActor
final class ScreenRecorder: NSObject, ObservableObject {

    enum State: Equatable {
        case idle
        case starting
        case recording(since: Date)
        case stopping

        var isBusy: Bool { self != .idle }
        var isRecording: Bool { if case .recording = self { return true }; return false }
    }

    struct Recording: Equatable {
        var url: URL
        var duration: TimeInterval
        var size: CGSize
        var bytes: Int64
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var latest: Recording?
    @Published var errorMessage: String?
    /// Frames per second. 30 is plenty for screen content and halves the file
    /// size versus 60; 60 is there for anything with animation.
    @Published var frameRate: Int = 30
    /// Whether to keep the cursor in the recording.
    @Published var showsCursor: Bool = true

    private var stream: SCStream?
    /// Owns the writer and receives frames directly on `sampleQueue`.
    private var sink: FrameSink?
    private var outputURL: URL?
    private var frameSize: CGSize = .zero
    private let sampleQueue = DispatchQueue(label: "com.macvital.recorder.samples")

    // MARK: - Start

    func start(excluding ownWindow: NSWindow?) async {
        guard state == .idle else { return }
        state = .starting

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                throw RecorderError.noDisplay
            }

            // Keep our own window out of the recording — otherwise the first
            // thing every capture shows is the app that started it.
            let excluded = ownWindow.map { window in
                content.windows.filter { $0.windowID == CGWindowID(window.windowNumber) }
            } ?? []

            let filter = SCContentFilter(display: display, excludingWindows: excluded)

            let configuration = SCStreamConfiguration()
            configuration.width = display.width * 2
            configuration.height = display.height * 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
            configuration.showsCursor = showsCursor
            configuration.queueDepth = 6
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            frameSize = CGSize(width: configuration.width, height: configuration.height)

            try prepareWriter()

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            // The sink, not `self`: frames are handled on `sampleQueue` and
            // never touch the main actor. See `FrameSink`.
            guard let sink else { throw RecorderError.writerRejectedInput }
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()

            self.stream = stream
            state = .recording(since: Date())
        } catch {
            await teardown()
            state = .idle
            errorMessage = Self.describe(error)
        }
    }

    private func prepareWriter() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacVital-Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).mp4")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(frameSize.width),
            AVVideoHeightKey: Int(frameSize.height),
            AVVideoCompressionPropertiesKey: [
                // Screen content is mostly static; a moderate bitrate with a
                // short keyframe interval keeps seeking responsive without
                // inflating the file.
                AVVideoAverageBitRateKey: Int(frameSize.width * frameSize.height * 0.09),
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecorderError.writerRejectedInput }
        writer.add(input)

        self.sink = FrameSink(writer: writer, input: input)
        self.outputURL = url
    }

    // MARK: - Stop

    func stop() async {
        guard state.isRecording else { return }
        state = .stopping

        try? await stream?.stopCapture()
        stream = nil

        let outcome = await sink?.finish() ?? .empty
        sink = nil

        switch outcome {
        case .completed:
            if let url = outputURL, FileManager.default.fileExists(atPath: url.path) {
                let asset = AVURLAsset(url: url)
                let duration = (try? await asset.load(.duration).seconds) ?? 0
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                latest = Recording(url: url, duration: duration, size: frameSize, bytes: bytes)
            }
        case .failed(let error):
            // A writer that failed leaves a file that cannot be played. It used
            // to be left in the temporary directory forever, because the only
            // thing that cleaned up was the success path.
            discardOutput()
            errorMessage = "录制失败：\(error?.localizedDescription ?? "编码器中止")"
        case .empty:
            // Stopped before a single complete frame arrived. Nothing to keep
            // and nothing to complain about.
            discardOutput()
        }

        outputURL = nil
        state = .idle
    }

    private func discardOutput() {
        guard let url = outputURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func teardown() async {
        try? await stream?.stopCapture()
        stream = nil
        _ = await sink?.finish()
        sink = nil
        discardOutput()
        outputURL = nil
    }

    // MARK: - Saving

    @discardableResult
    func saveToMovies() -> URL? {
        guard let latest else { return nil }
        guard let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first else {
            errorMessage = "找不到「影片」目录。"
            return nil
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        var target = movies.appendingPathComponent("录屏 \(formatter.string(from: Date())).mp4")
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = movies.appendingPathComponent("录屏 \(formatter.string(from: Date())) (\(counter)).mp4")
            counter += 1
        }
        do {
            try FileManager.default.copyItem(at: latest.url, to: target)
            return target
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
            return nil
        }
    }

    func revealLatest() {
        guard let latest else { return }
        NSWorkspace.shared.activateFileViewerSelecting([latest.url])
    }

    func discard() {
        if let latest { try? FileManager.default.removeItem(at: latest.url) }
        latest = nil
    }

    // MARK: - Errors

    enum RecorderError: LocalizedError {
        case noDisplay
        case writerRejectedInput

        var errorDescription: String? {
            switch self {
            case .noDisplay: return "找不到可录制的显示器。"
            case .writerRejectedInput: return "无法初始化视频编码器。"
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        ScreenCapturePermission.isDenial(error) ? ScreenCapturePermission.message : error.localizedDescription
    }
}

// MARK: - Stream plumbing

/// Owns the asset writer and takes frames on the capture queue.
///
/// Frames used to hop to the main actor, one `Task` per frame, and two separate
/// things were wrong with that. Independent `Task`s have no ordering guarantee,
/// so presentation timestamps could reach `append` out of order —
/// `AVAssetWriterInput` fails the whole writer on that, and the
/// `status == .writing` guard then silently swallows every later frame. The
/// result is a recording that stops early with no error reported anywhere. And
/// it put H.264 encoding of a 2x display, 30–60 times a second, on the thread
/// drawing the UI.
///
/// ScreenCaptureKit already hands frames to a serial queue of our choosing, in
/// order. Doing the work there is both correct and cheaper.
private final class FrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
    enum Outcome {
        /// A playable file was written.
        case completed
        /// No complete frame ever arrived.
        case empty
        case failed(Error?)
    }

    private let lock = NSLock()
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var started = false
    private var closed = false

    init(writer: AVAssetWriter, input: AVAssetWriterInput) {
        self.writer = writer
        self.input = input
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // ScreenCaptureKit delivers a frame for every vsync, including ones
        // where nothing changed. Those carry a status of `.idle` or `.blank`
        // and appending them stalls the writer with duplicate timestamps.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete
        else { return }

        append(sampleBuffer)
    }

    private func append(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }

        if writer.status == .unknown {
            let start = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: start)
            started = true
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    /// Closes the input and reports whether the file is usable. Safe to call
    /// more than once; later calls report `.empty`.
    func finish() async -> Outcome {
        // The lock is taken in this synchronous step and released before the
        // suspension point below. `NSLock` may not be held across an `await`:
        // the continuation can resume on a different thread, which is undefined
        // for a lock that must be unlocked by the thread that took it.
        let state = close()

        guard !state.wasClosed, state.didStart else { return .empty }
        guard state.status == .writing else { return .failed(writer.error) }

        await writer.finishWriting()
        return writer.status == .completed ? .completed : .failed(writer.error)
    }

    private struct CloseState {
        let wasClosed: Bool
        let didStart: Bool
        let status: AVAssetWriter.Status
    }

    private func close() -> CloseState {
        lock.lock()
        defer { lock.unlock() }
        let state = CloseState(wasClosed: closed, didStart: started, status: writer.status)
        closed = true
        if state.didStart, !state.wasClosed { input.markAsFinished() }
        return state
    }
}

extension ScreenRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.errorMessage = Self.describe(error)
            await self.stop()
        }
    }
}

