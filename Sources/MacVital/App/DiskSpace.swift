import Foundation

/// Volume capacity for the storage ring and the menu bar readout.
enum DiskSpace {
    struct Snapshot: Equatable {
        var total: Int64
        var free: Int64

        var used: Int64 { max(total - free, 0) }
        /// 0...1, for the ring.
        var usedFraction: Double {
            total > 0 ? Double(used) / Double(total) : 0
        }
    }

    /// `volumeAvailableCapacityForImportantUsage` rather than the raw free
    /// count: it is what Finder shows, because it includes space macOS would
    /// reclaim from purgeable caches under pressure. Quoting a smaller number
    /// than Finder does makes the app look wrong.
    static func current() -> Snapshot? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]) else { return nil }

        guard let total = values.volumeTotalCapacity else { return nil }
        let free = values.volumeAvailableCapacityForImportantUsage ?? 0
        return Snapshot(total: Int64(total), free: free)
    }
}
