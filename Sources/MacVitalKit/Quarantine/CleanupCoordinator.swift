import Foundation

public struct CleanupOutcome: Sendable {
    public var removed: [QuarantineRecord]
    public var skipped: [(item: ScanItem, reason: String)]
    /// Bytes moved into quarantine — **not** bytes returned to the volume.
    ///
    /// The quarantine store is on the same disk, so free space does not change
    /// until the retention window expires. This was called `reclaimedBytes` and
    /// the UI duly reported "已回收 X"; users then looked at their free space,
    /// saw it unmoved, and concluded the app had lied to them. It had.
    public var quarantinedBytes: Int64

    public init(removed: [QuarantineRecord], skipped: [(item: ScanItem, reason: String)], quarantinedBytes: Int64) {
        self.removed = removed
        self.skipped = skipped
        self.quarantinedBytes = quarantinedBytes
    }
}

/// Where the three inputs actually meet.
///
/// The engine already ran once at scan time, but that verdict is a snapshot.
/// This runs it again, item by item, immediately before each move — because
/// between the scan and the button press a build can start, an app can launch,
/// or a path can be replaced with a symlink. Anything that fails the second
/// pass is skipped with a reason, not forced through.
public struct CleanupCoordinator: Sendable {
    private let rules: RuleIndex
    private let store: QuarantineStore
    private let helper: HelperClient

    public init(rules: RuleIndex, store: QuarantineStore, helper: HelperClient) {
        self.rules = rules
        self.store = store
        self.helper = helper
    }

    /// - Parameters:
    ///   - findings: everything shown to the user.
    ///   - selection: the IDs the user actually ticked. Nothing outside this
    ///     set is touched, regardless of what the engine or the model said.
    public func execute(
        findings: [Finding],
        selection: Set<UUID>,
        progress: @Sendable (Int, Int, String) -> Void = { _, _, _ in }
    ) async -> CleanupOutcome {
        // `root` is an immutable Sendable property, so no actor hop is needed.
        let quarantineRoot = store.root.path
        let engine = RuleEngine(
            rules: rules,
            processIndex: RunningProcessIndex.snapshot(),
            selfProtectedPrefixes: [quarantineRoot],
            removalCheckLimit: nil
        )

        // Input 3: user authorisation. Start from the selection, not from the
        // findings — an item the user did not tick cannot enter the loop.
        let targets = findings.filter { selection.contains($0.id) }

        var removed: [QuarantineRecord] = []
        var skipped: [(ScanItem, String)] = []
        var quarantined: Int64 = 0

        for (index, finding) in targets.enumerated() {
            progress(index, targets.count, finding.item.displayName)

            // Input 2: rule engine, re-run against the live filesystem.
            let decision = engine.evaluate(finding.item)
            guard !decision.isDenied else {
                skipped.append((finding.item, decision.rationale))
                Log.quarantine.notice("skipped \(Log.path(finding.item.path), privacy: .public): \(decision.rationale, privacy: .public)")
                continue
            }

            if finding.item.category == .duplicateFiles,
               !DuplicateFileScanner.isStillDuplicate(finding.item) {
                skipped.append((
                    finding.item,
                    "文件或保留副本在扫描后发生变化，已重新校验并取消隔离。"
                ))
                continue
            }

            do {
                let record = try await store.store(
                    item: finding.item,
                    decision: decision,
                    assessment: finding.assessment,
                    privilegedMove: { source, destination in
                        let result = try await helper.moveToQuarantine(
                            paths: [source],
                            quarantineRoot: quarantineRoot
                        )
                        if let message = result.failures[source] {
                            throw HelperError.remote(message)
                        }
                        guard let landed = result.moved[source] else {
                            throw HelperError.remote("特权助手未返回隔离位置")
                        }
                        return landed
                    }
                )
                removed.append(record)
                quarantined += record.sizeBytes
            } catch {
                skipped.append((finding.item, error.localizedDescription))
                Log.quarantine.error("failed \(Log.path(finding.item.path), privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        progress(targets.count, targets.count, "")
        return CleanupOutcome(removed: removed, skipped: skipped, quarantinedBytes: quarantined)
    }

    // MARK: - Quarantine management

    public func restore(_ record: QuarantineRecord) async throws {
        let root = store.root.path
        try await store.restore(id: record.id) { source, destination in
            try await helper.restore(storedPath: source, originalPath: destination, quarantineRoot: root)
        }
    }

    public func purge(_ record: QuarantineRecord) async throws {
        let root = store.root.path
        try await store.purge(id: record.id) { paths in
            let failures = try await helper.purge(storedPaths: paths, quarantineRoot: root)
            if let first = failures.values.first { throw HelperError.remote(first) }
        }
    }

    public func discardOrphans(paths: Set<String>) async -> (removed: Int, bytes: Int64) {
        let root = store.root.path
        return await store.discardOrphans(paths: paths) { orphanPaths in
            let failures = try await helper.purge(storedPaths: orphanPaths, quarantineRoot: root)
            if let first = failures.values.first { throw HelperError.remote(first) }
        }
    }

    @discardableResult
    public func sweepExpired() async -> Int {
        let root = store.root.path
        let helper = self.helper
        return await store.sweepExpired { paths in
            let failures = try await helper.purge(storedPaths: paths, quarantineRoot: root)
            if let first = failures.values.first { throw HelperError.remote(first) }
        }
    }
}
