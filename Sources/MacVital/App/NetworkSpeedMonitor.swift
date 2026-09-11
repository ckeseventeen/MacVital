import Foundation
import Darwin

/// Live throughput for the menu bar.
///
/// Reads the kernel's per-interface byte counters and differences them over
/// time. Uses `sysctl(NET_RT_IFLIST2)` rather than the more obvious
/// `getifaddrs`: the latter reports `if_data`, whose counters are 32-bit and
/// wrap every 4 GB — minutes apart on a fast link, and every wrap shows up as a
/// bogus spike or a dead second. `if_msghdr2` carries `if_data64`.
@MainActor
final class NetworkSpeedMonitor: ObservableObject {
    typealias Sample = NetworkByteCounters

    /// Bytes per second, smoothed.
    @Published private(set) var downloadRate: Double = 0
    @Published private(set) var uploadRate: Double = 0

    private var previous: Sample?
    private var previousTime: CFAbsoluteTime?
    private var timer: Timer?

    /// Exponential smoothing. Raw per-second deltas jitter enough to make the
    /// menu bar text flicker; this keeps it readable without lagging visibly.
    private let smoothing = 0.4

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        previous = Self.read()
        previousTime = CFAbsoluteTimeGetCurrent()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // `.common` so the rate keeps updating while a menu is open or the
        // window is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        previous = nil
        previousTime = nil
        downloadRate = 0
        uploadRate = 0
    }

    private func tick() {
        let now = CFAbsoluteTimeGetCurrent()
        let sample = Self.read()
        defer {
            previous = sample
            previousTime = now
        }
        guard let previous, let previousTime, now > previousTime else { return }

        let elapsed = now - previousTime
        // Counters are monotonic; a decrease means an interface went away or
        // was reset, so drop the interval rather than reporting a negative.
        let deltaIn = sample.bytesIn >= previous.bytesIn ? sample.bytesIn - previous.bytesIn : 0
        let deltaOut = sample.bytesOut >= previous.bytesOut ? sample.bytesOut - previous.bytesOut : 0

        let rawDown = Double(deltaIn) / elapsed
        let rawUp = Double(deltaOut) / elapsed
        downloadRate += (rawDown - downloadRate) * smoothing
        uploadRate += (rawUp - uploadRate) * smoothing
    }

    // MARK: - Kernel counters

    private static func read() -> Sample {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
            return Sample()
        }

        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else {
            return Sample()
        }

        return buffer.withUnsafeBytes { raw in
            NetworkRouteParser.parse(
                UnsafeRawBufferPointer(rebasing: raw.prefix(min(length, raw.count)))
            )
        }
    }
}

enum SpeedFormat {
    /// Compact and fixed-width-ish, so the menu bar item does not resize on
    /// every sample. Decimal units, matching how link speeds are quoted.
    static func string(_ bytesPerSecond: Double) -> String {
        let value = max(bytesPerSecond, 0)
        if value < 1_000 { return String(format: "%.0f B/s", value) }
        if value < 1_000_000 { return String(format: "%.0f KB/s", value / 1_000) }
        if value < 10_000_000 { return String(format: "%.1f MB/s", value / 1_000_000) }
        if value < 1_000_000_000 { return String(format: "%.0f MB/s", value / 1_000_000) }
        return String(format: "%.1f GB/s", value / 1_000_000_000)
    }
}
