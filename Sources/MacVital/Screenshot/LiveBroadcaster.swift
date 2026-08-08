import AppKit
import CoreImage
import Network
import ScreenCaptureKit

/// Live screen broadcast over the local network.
///
/// **What this is not:** RTMP push to Twitch / YouTube / Bilibili. There is no
/// RTMP framework on macOS, so that path means hand-writing the handshake,
/// chunk stream, AMF encoding and FLV muxing — a thousand-plus lines that
/// cannot be tested without a stream key and a server, and that would be the
/// least reliable code in this app by a wide margin.
///
/// **What this is:** an HTTP server on the LAN serving the screen as MJPEG.
/// Anyone on the same network opens a URL in any browser — no plugin, no app,
/// no account. MJPEG rather than HLS on purpose: HLS means segmenting, a
/// playlist, fMP4 muxing and several seconds of built-in latency, while MJPEG
/// is a sequence of JPEGs in a multipart response that every browser has
/// rendered natively for twenty years. It costs bandwidth (no inter-frame
/// compression) and that is the right trade on a LAN, for the classroom and
/// meeting-room case this feature is actually for.
@MainActor
final class LiveBroadcaster: NSObject, ObservableObject {

    @Published private(set) var isBroadcasting = false
    @Published private(set) var viewerCount = 0
    @Published private(set) var addresses: [String] = []
    @Published var errorMessage: String?
    /// Lower is smoother, higher costs bandwidth. Screen content tolerates a
    /// low rate far better than video does.
    @Published var frameRate: Int = 12
    @Published var quality: Double = 0.6

    let port: UInt16 = 8760

    private var listener: NWListener?
    private var stream: SCStream?
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private let context = CIContext()
    private var latestJPEG: Data?
    private var lastFrameAt: CFAbsoluteTime = 0
    private let sampleQueue = DispatchQueue(label: "com.macvital.live.samples")

    private static let boundary = "macvitalframe"

    var url: String? { addresses.first.map { "http://\($0):\(port)" } }

    // MARK: - Lifecycle

    func toggle(excluding ownWindow: NSWindow?) async {
        isBroadcasting ? stop() : await start(excluding: ownWindow)
    }

    func start(excluding ownWindow: NSWindow?) async {
        guard !isBroadcasting else { return }
        do {
            try startServer()
            try await startCapture(excluding: ownWindow)
            addresses = Self.localAddresses()
            isBroadcasting = true
        } catch {
            stop()
            errorMessage = Self.describe(error)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in clients.values { connection.cancel() }
        clients.removeAll()
        viewerCount = 0

        let stream = self.stream
        self.stream = nil
        Task { try? await stream?.stopCapture() }

        latestJPEG = nil
        addresses = []
        isBroadcasting = false
    }

    // MARK: - Server

    private func startServer() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)

        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .failed(let error) = state else { return }
            Task { @MainActor in
                self?.errorMessage = "监听端口 \(self?.port ?? 0) 失败：\(error.localizedDescription)"
                self?.stop()
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        // One read is enough: we only care whether the request line asks for
        // the page or the stream, and both fit in the first packet.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self else { return }
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                if request.contains("GET /stream") {
                    self.beginStream(on: connection)
                } else {
                    self.servePage(on: connection)
                }
            }
        }
    }

    private func servePage(on connection: NWConnection) {
        let html = Self.page(port: port)
        let body = Data(html.utf8)
        var response = "HTTP/1.1 200 OK\r\n"
        response += "Content-Type: text/html; charset=utf-8\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n\r\n"
        connection.send(content: Data(response.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func beginStream(on connection: NWConnection) {
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: multipart/x-mixed-replace; boundary=\(Self.boundary)\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"

        let key = ObjectIdentifier(connection)
        clients[key] = connection
        viewerCount = clients.count

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                Task { @MainActor in self?.drop(key) }
            default:
                break
            }
        }
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in })

        // Send the current frame immediately so the page is not blank until the
        // screen next changes.
        if let jpeg = latestJPEG { send(jpeg, to: connection) }
    }

    private func drop(_ key: ObjectIdentifier) {
        clients[key]?.cancel()
        clients.removeValue(forKey: key)
        viewerCount = clients.count
    }

    private func broadcast(_ jpeg: Data) {
        for (key, connection) in clients {
            guard connection.state == .ready else {
                drop(key)
                continue
            }
            send(jpeg, to: connection)
        }
    }

    private func send(_ jpeg: Data, to connection: NWConnection) {
        var part = "--\(Self.boundary)\r\n"
        part += "Content-Type: image/jpeg\r\n"
        part += "Content-Length: \(jpeg.count)\r\n\r\n"
        connection.send(content: Data(part.utf8) + jpeg + Data("\r\n".utf8),
                        completion: .contentProcessed { _ in })
    }

    // MARK: - Capture

    private func startCapture(excluding ownWindow: NSWindow?) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw ScreenRecorder.RecorderError.noDisplay }

        let excluded = ownWindow.map { window in
            content.windows.filter { $0.windowID == CGWindowID(window.windowNumber) }
        } ?? []

        let configuration = SCStreamConfiguration()
        // Broadcast at 1x, not Retina: viewers are watching in a browser window
        // and doubling the pixels quadruples the bandwidth for no visible gain.
        configuration.width = display.width
        configuration.height = display.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        configuration.showsCursor = true
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let stream = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: excluded),
            configuration: configuration,
            delegate: self
        )
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    fileprivate func encodeAndBroadcast(_ sampleBuffer: CMSampleBuffer) {
        // Rate-limit here as well as in the stream config: a burst of frames
        // would otherwise queue JPEGs faster than the sockets drain them.
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFrameAt >= 1.0 / Double(frameRate) else { return }
        lastFrameAt = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let jpeg = context.jpegRepresentation(
            of: image,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        ) else { return }

        latestJPEG = jpeg
        guard !clients.isEmpty else { return }
        broadcast(jpeg)
    }

    // MARK: - Addresses

    /// IPv4 addresses on real interfaces, so the user can read a URL off the
    /// screen and type it on another device. Loopback is useless for that.
    private static func localAddresses() -> [String] {
        var results: [String] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = entry.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            if !address.isEmpty, address != "127.0.0.1", !results.contains(address) {
                results.append(address)
            }
        }
        return results
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain", nsError.code == -3801 {
            return "没有「屏幕录制」权限。请到「系统设置 → 隐私与安全性 → 屏幕录制」中勾选 MacVital，然后重启 App。"
        }
        return error.localizedDescription
    }

    private static func page(port: UInt16) -> String {
        """
        <!DOCTYPE html><html lang="zh"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>MacVital 屏幕直播</title>
        <style>
          html,body{margin:0;height:100%;background:#111;display:flex;
            align-items:center;justify-content:center;font-family:-apple-system,system-ui,sans-serif}
          img{max-width:100%;max-height:100%;object-fit:contain}
          p{color:#888;font-size:14px}
        </style></head>
        <body><img src="/stream" alt="屏幕直播"
          onerror="document.body.innerHTML='<p>直播已结束</p>'"></body></html>
        """
    }
}

extension LiveBroadcaster: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete
        else { return }

        Task { @MainActor in self.encodeAndBroadcast(sampleBuffer) }
    }
}

extension LiveBroadcaster: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.errorMessage = Self.describe(error)
            self.stop()
        }
    }
}
