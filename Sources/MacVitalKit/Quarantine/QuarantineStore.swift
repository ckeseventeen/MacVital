import Foundation

/// Nothing is ever deleted directly. Every removal is a move into this store,
/// and the hard delete happens on a timer afterwards.
///
/// This single design decision absorbs most of the support burden in this
/// category of app: a false positive becomes a one-click restore instead of a
/// data-loss incident. The cost is disk space that is not returned to the user
/// for `retentionDays` — which is why the UI says so plainly.
public actor QuarantineStore {
    public static let defaultRetentionDays = 7

    /// Immutable and set in `init`, so it is safe to read without hopping onto
    /// the actor. Callers on the main actor need it to build the scan engine's
    /// self-protection prefix list before any async work has happened.
    public nonisolated let root: URL
    private let itemsDirectory: URL
    private let manifestURL: URL
    private let retentionDays: Int
    private var records: [QuarantineRecord] = []
    private var loaded = false

    public init(root: URL? = nil, retentionDays: Int = QuarantineStore.defaultRetentionDays) {
        let base = root ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacVital", isDirectory: true)
            .appendingPathComponent("Quarantine", isDirectory: true)
        self.root = base
        self.itemsDirectory = base.appendingPathComponent("Items", isDirectory: true)
        self.manifestURL = base.appendingPathComponent("manifest.json")
        self.retentionDays = retentionDays
    }

    // MARK: - Lifecycle

    public func prepare() throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: itemsDirectory, withIntermediateDirectories: true)
        } catch {
            throw QuarantineError.rootUnavailable(error.localizedDescription)
        }
        loadIfNeeded()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: manifestURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([QuarantineRecord].self, from: data)) ?? []
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: manifestURL, options: [.atomic])
    }

    public func allRecords() -> [QuarantineRecord] {
        loadIfNeeded()
        return records.sorted { $0.quarantinedAt > $1.quarantinedAt }
    }

    public func totalBytes() -> Int64 {
        loadIfNeeded()
        return records.reduce(0) { $0 + $1.sizeBytes }
    }

    // MARK: - Store

    /// Move an item in. `privilegedMove` is supplied by the caller so this type
    /// stays free of XPC: for a root-owned path the coordinator hands us a
    /// closure that asks the helper to do the move.
    public func store(
        item: ScanItem,
        decision: RuleDecision,
        assessment: AIAssessment?,
        privilegedMove: ((_ source: String, _ destination: String) async throws -> Void)? = nil
    ) async throws -> QuarantineRecord {
        try prepare()

        let source = URL(fileURLWithPath: item.path)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw QuarantineError.sourceMissing(item.path)
        }

        let recordID = UUID()
        let container = itemsDirectory.appendingPathComponent(recordID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let destination = container.appendingPathComponent(source.lastPathComponent)

        if decision.admission == .allowWithPrivilege {
            guard let privilegedMove else { throw QuarantineError.privilegeRequired }
            try await privilegedMove(source.path, destination.path)
        } else {
            try moveOrCopy(from: source, to: destination)
        }

        let record = QuarantineRecord(
            id: recordID,
            originalPath: item.path,
            storedPath: destination.path,
            displayName: item.displayName,
            category: item.category,
            sizeBytes: item.sizeBytes,
            purgeAfter: Calendar.current.date(byAdding: .day, value: retentionDays, to: Date()) ?? Date(),
            ruleID: decision.ruleID,
            rationale: decision.rationale,
            aiSummary: assessment.map { "\($0.whatItIs) \($0.consequence)" },
            usedPrivilegedHelper: decision.admission == .allowWithPrivilege
        )
        records.append(record)
        persist()
        Log.quarantine.info("quarantined \(Log.path(item.path), privacy: .public) (\(item.sizeBytes) bytes)")
        return record
    }

    // MARK: - Restore

    public func restore(
        id: UUID,
        privilegedMove: ((_ source: String, _ destination: String) async throws -> Void)? = nil
    ) async throws {
        loadIfNeeded()
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw QuarantineError.recordNotFound
        }
        let record = records[index]
        let stored = URL(fileURLWithPath: record.storedPath)
        let original = URL(fileURLWithPath: record.originalPath)

        guard FileManager.default.fileExists(atPath: stored.path) else {
            throw QuarantineError.sourceMissing(record.storedPath)
        }
        // Never overwrite. If something new is at the original path, the user
        // has to resolve it — silently clobbering it would be the exact class
        // of accident quarantine exists to prevent.
        guard !FileManager.default.fileExists(atPath: original.path) else {
            throw QuarantineError.destinationOccupied(record.originalPath)
        }

        let parent = original.deletingLastPathComponent()
        if record.usedPrivilegedHelper {
            guard let privilegedMove else { throw QuarantineError.privilegeRequired }
            try await privilegedMove(stored.path, original.path)
        } else {
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try moveOrCopy(from: stored, to: original)
        }

        try? FileManager.default.removeItem(at: stored.deletingLastPathComponent())
        records.remove(at: index)
        persist()
        Log.quarantine.info("restored \(Log.path(record.originalPath), privacy: .public)")
    }

    // MARK: - Purge

    /// Hard delete a single record ahead of schedule, at the user's request.
    public func purge(
        id: UUID,
        privilegedDelete: ((_ paths: [String]) async throws -> Void)? = nil
    ) async throws {
        loadIfNeeded()
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw QuarantineError.recordNotFound
        }
        let record = records[index]
        try await remove(record: record, privilegedDelete: privilegedDelete)
        records.remove(at: index)
        persist()
    }

    /// The 7-day timer. Called on launch and periodically thereafter.
    @discardableResult
    public func sweepExpired(
        privilegedDelete: ((_ paths: [String]) async throws -> Void)? = nil
    ) async -> Int {
        loadIfNeeded()
        let expired = records.filter(\.isExpired)
        guard !expired.isEmpty else { return 0 }

        var purged = 0
        for record in expired {
            do {
                try await remove(record: record, privilegedDelete: privilegedDelete)
                records.removeAll { $0.id == record.id }
                purged += 1
            } catch {
                Log.quarantine.error("sweep failed for \(record.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if purged > 0 { persist() }
        Log.quarantine.info("swept \(purged, privacy: .public) expired records")
        return purged
    }

    private func remove(
        record: QuarantineRecord,
        privilegedDelete: ((_ paths: [String]) async throws -> Void)?
    ) async throws {
        let container = URL(fileURLWithPath: record.storedPath).deletingLastPathComponent()
        // Sanity check: only ever delete inside our own Items directory.
        guard container.path.hasPrefix(itemsDirectory.path + "/") else {
            throw QuarantineError.moveFailed("隔离记录路径异常，拒绝删除")
        }
        do {
            try FileManager.default.removeItem(at: container)
        } catch {
            if let privilegedDelete {
                try await privilegedDelete([container.path])
            } else {
                throw QuarantineError.moveFailed(error.localizedDescription)
            }
        }
    }

    // MARK: - Helpers

    /// `moveItem` fails across volumes (EXDEV). Fall back to copy + remove so
    /// an external disk does not break the flow.
    private nonisolated func moveOrCopy(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        do {
            try fm.moveItem(at: source, to: destination)
            return
        } catch {
            do {
                try fm.copyItem(at: source, to: destination)
                try fm.removeItem(at: source)
            } catch {
                throw QuarantineError.moveFailed(error.localizedDescription)
            }
        }
    }
}
