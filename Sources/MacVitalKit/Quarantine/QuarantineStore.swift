import Darwin
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
    /// A closure, not a stored `Int`.
    ///
    /// The retention window is a live user setting, and it used to be captured
    /// once when the store was constructed at launch. Changing it in Settings
    /// then did nothing until the next relaunch — while the confirm sheet went
    /// on promising "N 天后才清除" with the *new* number. Reading it at the
    /// moment an expiry is stamped is the only version of this that is true.
    private let retentionDays: @Sendable () -> Int
    private var records: [QuarantineRecord] = []
    private var loaded = false
    /// Non-nil when the manifest exists but could not be decoded. Latches for
    /// the lifetime of the store and blocks every write.
    private var manifestUnreadable: String?

    public init(root: URL? = nil, retentionDaysProvider: @escaping @Sendable () -> Int) {
        let base = root ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacVital", isDirectory: true)
            .appendingPathComponent("Quarantine", isDirectory: true)
        self.root = base
        self.itemsDirectory = base.appendingPathComponent("Items", isDirectory: true)
        self.manifestURL = base.appendingPathComponent("manifest.json")
        self.retentionDays = retentionDaysProvider
    }

    /// Fixed-window convenience, for tests and for callers with no setting to
    /// read.
    public init(root: URL? = nil, retentionDays: Int = QuarantineStore.defaultRetentionDays) {
        self.init(root: root, retentionDaysProvider: { retentionDays })
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

    /// Loads the manifest, and refuses to proceed if one exists but cannot be
    /// read.
    ///
    /// This used to be `(try? decode(...)) ?? []`. A manifest that failed to
    /// decode — a truncated write, a schema change, a kill mid-save — silently
    /// became an empty record list, and the *next* `persist()` wrote that empty
    /// list back over the real one. Every file quarantined up to that point was
    /// orphaned: still on disk, invisible in the UI, never restorable, never
    /// swept. On the machine this was found on, 102 non-empty containers had
    /// accumulated that way.
    ///
    /// So a decode failure now latches `manifestUnreadable`, which blocks every
    /// write, and the damaged file is copied aside instead of being overwritten.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true

        // No manifest at all is the normal first run, not a failure.
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return }

        guard let data = try? Data(contentsOf: manifestURL) else {
            manifestUnreadable = "清单文件存在但无法读取"
            Log.quarantine.error("manifest present but unreadable; refusing to write")
            return
        }
        // A zero-byte manifest is what an interrupted atomic write leaves. It
        // carries no records, but it is also not evidence that there are none.
        guard !data.isEmpty else {
            manifestUnreadable = "清单文件为空"
            Log.quarantine.error("manifest is empty; refusing to write")
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let decoded = try decoder.decode([QuarantineRecord].self, from: data)
            guard decoded.allSatisfy({ isValidStoredPath($0) }) else {
                throw QuarantineError.manifestUnreadable("清单包含隔离区之外或编号不匹配的路径")
            }
            records = decoded
            reconcilePendingOperations()
        } catch {
            manifestUnreadable = error.localizedDescription
            let backup = manifestURL.deletingLastPathComponent()
                .appendingPathComponent("manifest.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: manifestURL, to: backup)
            Log.quarantine.error("manifest failed to decode; copied aside, refusing to write: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist() throws {
        if let reason = manifestUnreadable {
            throw QuarantineError.manifestUnreadable(reason)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(records)
            try data.write(to: manifestURL, options: [.atomic])
        } catch {
            // Swallowing this was the other half of the same bug: a record that
            // never reached disk describes a file that can no longer be found,
            // restored or purged.
            Log.quarantine.error("manifest write failed: \(error.localizedDescription, privacy: .public)")
            throw QuarantineError.manifestWriteFailed(error.localizedDescription)
        }
    }

    public func allRecords() -> [QuarantineRecord] {
        loadIfNeeded()
        return records
            .filter { $0.pendingOperation == nil }
            .sorted { $0.quarantinedAt > $1.quarantinedAt }
    }

    public func totalBytes() -> Int64 {
        loadIfNeeded()
        return records
            .filter { $0.pendingOperation == nil }
            .reduce(0) { $0 + $1.sizeBytes }
    }

    // MARK: - Store

    /// Move an item in. `privilegedMove` is supplied by the caller so this type
    /// stays free of XPC: for a root-owned path the coordinator hands us a
    /// closure that asks the helper to do the move.
    public func store(
        item: ScanItem,
        decision: RuleDecision,
        assessment: AIAssessment?,
        privilegedMove: ((_ source: String, _ suggestedDestination: String) async throws -> String)? = nil
    ) async throws -> QuarantineRecord {
        try prepare()

        let source = URL(fileURLWithPath: item.path)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw QuarantineError.sourceMissing(item.path)
        }

        var recordID = UUID()
        var container = itemsDirectory.appendingPathComponent(recordID.uuidString, isDirectory: true)
        var destination = container.appendingPathComponent(source.lastPathComponent)

        // A failed move must not leave its container behind. The sweep only
        // ever visits directories named by a manifest record, so an orphan
        // created here is one nothing in the app will ever collect.
        do {
            if decision.admission == .allowWithPrivilege {
                guard let privilegedMove else { throw QuarantineError.privilegeRequired }
                let landed = URL(fileURLWithPath: try await privilegedMove(source.path, destination.path))
                container = landed.deletingLastPathComponent()
                guard container.deletingLastPathComponent().standardizedFileURL == itemsDirectory.standardizedFileURL,
                      let helperID = UUID(uuidString: container.lastPathComponent),
                      landed.lastPathComponent == source.lastPathComponent
                else {
                    throw QuarantineError.moveFailed("特权助手返回了异常的隔离路径")
                }
                recordID = helperID
                destination = landed
            } else {
                try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
                try moveOrCopy(from: source, to: destination)
            }
        } catch {
            if decision.admission != .allowWithPrivilege {
                try? FileManager.default.removeItem(at: container)
            }
            throw error
        }

        let record = QuarantineRecord(
            id: recordID,
            originalPath: item.path,
            storedPath: destination.path,
            displayName: item.displayName,
            category: item.category,
            sizeBytes: item.sizeBytes,
            purgeAfter: Calendar.current.date(byAdding: .day, value: retentionDays(), to: Date()) ?? Date(),
            ruleID: decision.ruleID,
            rationale: decision.rationale,
            aiSummary: assessment.map { "\($0.whatItIs) \($0.consequence)" },
            usedPrivilegedHelper: decision.admission == .allowWithPrivilege
        )
        records.append(record)
        do {
            try persist()
        } catch {
            // The file has already moved. A record we cannot write describes a
            // file nothing could ever restore or purge, so put it back rather
            // than leave it stranded.
            //
            // The container may only be removed once the item is provably out
            // of it. This used to remove it unconditionally, which for a
            // privileged move — where we cannot put the item back without the
            // helper — deleted the user's file outright: not at its original
            // path, not in quarantine, and named by no record. An orphan
            // container is recoverable (the quarantine screen lists and reveals
            // them); a deleted file is not.
            records.removeLast()

            var movedBack = false
            if decision.admission != .allowWithPrivilege {
                do {
                    try moveOrCopy(from: destination, to: source)
                    movedBack = true
                } catch {
                    Log.quarantine.error("could not move \(Log.path(item.path), privacy: .public) back: \(error.localizedDescription, privacy: .public)")
                }
            }

            if movedBack {
                try? FileManager.default.removeItem(at: container)
                Log.quarantine.error("rolled back \(Log.path(item.path), privacy: .public) after manifest failure")
            } else {
                Log.quarantine.error("\(Log.path(item.path), privacy: .public) is stranded in \(container.lastPathComponent, privacy: .public) after manifest failure; left in place for orphan recovery")
            }
            throw error
        }
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
        guard record.pendingOperation == nil, isValidStoredPath(record) else {
            throw QuarantineError.moveFailed("隔离记录正在处理或路径异常")
        }
        let stored = URL(fileURLWithPath: record.storedPath)
        let original = URL(fileURLWithPath: record.originalPath)

        let sourceExists = record.usedPrivilegedHelper
            ? FileManager.default.fileExists(atPath: stored.deletingLastPathComponent().path)
            : FileManager.default.fileExists(atPath: stored.path)
        guard sourceExists else {
            throw QuarantineError.sourceMissing(record.storedPath)
        }
        // Never overwrite. If something new is at the original path, the user
        // has to resolve it — silently clobbering it would be the exact class
        // of accident quarantine exists to prevent.
        guard !FileManager.default.fileExists(atPath: original.path) else {
            throw QuarantineError.destinationOccupied(record.originalPath)
        }

        try beginOperation(.restoring, at: index)

        do {
            let parent = original.deletingLastPathComponent()
            if record.usedPrivilegedHelper {
                guard let privilegedMove else { throw QuarantineError.privilegeRequired }
                try await privilegedMove(stored.path, original.path)
            } else {
                try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                try moveOrCopy(from: stored, to: original)
            }
        } catch {
            clearPendingOperation(for: id)
            throw error
        }

        try? FileManager.default.removeItem(at: stored.deletingLastPathComponent())
        records.removeAll { $0.id == id }
        persistCompletedOperation("restore", id: id)
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
        guard record.pendingOperation == nil, isValidStoredPath(record) else {
            throw QuarantineError.moveFailed("隔离记录正在处理或路径异常")
        }

        try beginOperation(.purging, at: index)
        do {
            try await remove(record: record, privilegedDelete: privilegedDelete)
        } catch {
            clearPendingOperation(for: id)
            throw error
        }
        records.removeAll { $0.id == id }
        persistCompletedOperation("purge", id: id)
    }

    /// The 7-day timer. Called on launch and periodically thereafter.
    @discardableResult
    public func sweepExpired(
        privilegedDelete: ((_ paths: [String]) async throws -> Void)? = nil
    ) async -> Int {
        loadIfNeeded()
        let expired = records.filter { $0.pendingOperation == nil && $0.isExpired }
        guard !expired.isEmpty else { return 0 }

        var purged = 0
        for record in expired {
            do {
                guard let index = records.firstIndex(where: { $0.id == record.id }),
                      records[index].pendingOperation == nil else { continue }
                try beginOperation(.purging, at: index)
                try await remove(record: record, privilegedDelete: privilegedDelete)
                records.removeAll { $0.id == record.id }
                persistCompletedOperation("sweep", id: record.id)
                purged += 1
            } catch {
                clearPendingOperation(for: record.id)
                Log.quarantine.error("sweep failed for \(record.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        Log.quarantine.info("swept \(purged, privacy: .public) expired records")
        return purged
    }

    // MARK: - Orphans

    /// A container under `Items/` that no manifest record points at.
    ///
    /// These are unreachable by design: the UI lists records, and the sweep
    /// only visits directories a record names. Anything here is invisible,
    /// unrestorable and permanent until something collects it.
    public struct Orphan: Identifiable, Sendable, Hashable {
        public var id: String { path }
        public var path: String
        public var name: String
        public var sizeBytes: Int64
        public var isEmpty: Bool
        public var modified: Date?
    }

    public func orphanedContainers() -> [Orphan] {
        loadIfNeeded()
        // While the manifest is unreadable we do not know what is referenced,
        // so nothing may be called an orphan.
        guard manifestUnreadable == nil else { return [] }

        let known = Set(records.map { URL(fileURLWithPath: $0.storedPath).deletingLastPathComponent().path })
        var found: [Orphan] = []

        for child in FileWalker.children(of: itemsDirectory) {
            let path = child.path
            guard !known.contains(path) else { continue }
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            // Only ever the UUID-shaped directories this store creates itself.
            guard UUID(uuidString: child.lastPathComponent) != nil else { continue }

            let contents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            let attributes = FileWalker.attributes(of: child)
            found.append(Orphan(
                path: path,
                name: contents.first ?? child.lastPathComponent,
                sizeBytes: contents.isEmpty ? 0 : FileWalker.size(of: child),
                isEmpty: contents.isEmpty,
                modified: attributes.modified
            ))
        }
        return found.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Delete orphan containers. Re-derives the orphan set rather than trusting
    /// the caller's list, so a stale UI cannot name a live record's container.
    @discardableResult
    public func discardOrphans(
        paths: Set<String>,
        privilegedDelete: ((_ paths: [String]) async throws -> Void)? = nil
    ) async -> (removed: Int, bytes: Int64) {
        let orphans = orphanedContainers().filter { paths.contains($0.path) }
        var removed = 0
        var bytes: Int64 = 0
        for orphan in orphans {
            guard orphan.path.hasPrefix(itemsDirectory.path + "/") else { continue }
            do {
                try FileManager.default.removeItem(atPath: orphan.path)
                removed += 1
                bytes += orphan.sizeBytes
            } catch {
                let localError = error
                guard let privilegedDelete else {
                    Log.quarantine.error("could not remove orphan: \(localError.localizedDescription, privacy: .public)")
                    continue
                }
                do {
                    try await privilegedDelete([orphan.path])
                    removed += 1
                    bytes += orphan.sizeBytes
                } catch {
                    Log.quarantine.error("could not remove orphan locally (\(localError.localizedDescription, privacy: .public)) or with helper (\(error.localizedDescription, privacy: .public))")
                }
            }
        }
        Log.quarantine.info("discarded \(removed, privacy: .public) orphan containers")
        return (removed, bytes)
    }

    private func remove(
        record: QuarantineRecord,
        privilegedDelete: ((_ paths: [String]) async throws -> Void)?
    ) async throws {
        guard isValidStoredPath(record) else {
            throw QuarantineError.moveFailed("隔离记录路径异常，拒绝删除")
        }
        let container = URL(fileURLWithPath: record.storedPath).deletingLastPathComponent()
        do {
            try FileManager.default.removeItem(at: container)
        } catch {
            let local = error
            guard let privilegedDelete else {
                throw QuarantineError.moveFailed(Self.explain(localFailure: local, at: container.path))
            }
            do {
                try await privilegedDelete([container.path])
            } catch {
                // Report why the *plain* delete failed, not why the fallback
                // did. The helper is a fallback for root-owned files; when the
                // block is actually TCC — two containers here were owned by the
                // user, mode 700, no restricted flags — surfacing the helper's
                // code-signing complaint sends the user after the wrong thing
                // entirely.
                throw QuarantineError.moveFailed(
                    Self.explain(localFailure: local, at: container.path)
                    + "（特权助手也不可用：\(error.localizedDescription)）"
                )
            }
        }
    }

    /// Turns a `removeItem` failure into something the user can act on.
    ///
    /// Checks the ACL before blaming permissions. The first version of this
    /// text sent the user after Full Disk Access, which does nothing here: the
    /// two directories that would not go away carried
    /// `group:everyone deny delete`, and no amount of TCC or privilege lifts
    /// that — `sudo rm` fails on it too.
    private static func explain(localFailure error: Error, at path: String) -> String {
        if SIPGuard.hasDeleteDenyACL(at: path) {
            return "\(PathRedaction.abbreviate(path)) 里有内容带着「禁止删除」的 ACL"
                 + "（macOS 给 Spelling、FontCollections 这类目录加的保护），"
                 + "所以它既删不掉也还原不了 —— 提升权限没有用。"
                 + "在访达中打开后用终端执行 chmod -a# 0 <路径> 移除该 ACL，再回来操作。"
        }

        let code = (error as NSError).code
        let posix = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        if code == NSFileWriteNoPermissionError || code == NSFileReadNoPermissionError
            || posix?.code == Int(EPERM) || posix?.code == Int(EACCES) {
            return "系统拒绝访问 \(PathRedaction.abbreviate(path))，可能缺少「完整磁盘访问权限」。"
        }
        return error.localizedDescription
    }

    // MARK: - Helpers

    private func isValidStoredPath(_ record: QuarantineRecord) -> Bool {
        let stored = URL(fileURLWithPath: record.storedPath).standardizedFileURL
        let container = stored.deletingLastPathComponent()
        guard !stored.lastPathComponent.isEmpty,
              container.deletingLastPathComponent() == itemsDirectory.standardizedFileURL,
              container.lastPathComponent == record.id.uuidString
        else { return false }
        return true
    }

    /// Resolve durable intent after a crash or a failed final manifest write.
    /// The pre-operation marker means absence/presence is enough to determine
    /// which side committed; ambiguous states remain visible and actionable.
    private func reconcilePendingOperations() {
        var changed = false
        // Iterate over a snapshot because successful reconciliation removes
        // entries from the live manifest array.
        for record in records.filter({ $0.pendingOperation != nil }) {
            let container = URL(fileURLWithPath: record.storedPath).deletingLastPathComponent()
            let containerExists = FileManager.default.fileExists(atPath: container.path)
            let originalExists = FileManager.default.fileExists(atPath: record.originalPath)
            let storedItemExists = FileManager.default.fileExists(atPath: record.storedPath)
            let sourceStillExists = record.usedPrivilegedHelper ? containerExists : storedItemExists

            switch record.pendingOperation {
            case .purging where !containerExists:
                records.removeAll { $0.id == record.id }
                changed = true
            // Seeing something at the destination alone is not proof: another
            // process may have recreated it after the preflight check. A
            // restore committed only when the quarantined source disappeared.
            case .restoring where originalExists && !sourceStillExists:
                records.removeAll { $0.id == record.id }
                changed = true
            case .purging, .restoring:
                if let index = records.firstIndex(where: { $0.id == record.id }) {
                    records[index].pendingOperation = nil
                    changed = true
                }
            case nil:
                break
            }
        }
        guard changed else { return }
        do {
            try persist()
        } catch {
            Log.quarantine.error("could not persist reconciled manifest: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Publish a busy record only after its recovery marker reaches disk.
    /// On write failure no filesystem mutation has begun, so keep it retryable.
    private func beginOperation(_ operation: QuarantineOperation, at index: Int) throws {
        records[index].pendingOperation = operation
        do {
            try persist()
        } catch {
            records[index].pendingOperation = nil
            throw error
        }
    }

    private func clearPendingOperation(for id: UUID) {
        if let index = records.firstIndex(where: { $0.id == id }) {
            records[index].pendingOperation = nil
        }
        do {
            try persist()
        } catch {
            Log.quarantine.error("could not clear pending operation for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Failure here is recoverable: the on-disk manifest still contains the
    /// pending marker written before the filesystem mutation, so next launch
    /// reconciles it instead of resurrecting a stale record.
    private func persistCompletedOperation(_ operation: String, id: UUID) {
        do {
            try persist()
        } catch {
            Log.quarantine.error("\(operation, privacy: .public) completed for \(id, privacy: .public); pending manifest will reconcile on next launch: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `moveItem` fails across volumes (EXDEV). Fall back to copy + remove so
    /// an external disk does not break the flow.
    private nonisolated func moveOrCopy(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        do {
            try fm.moveItem(at: source, to: destination)
            return
        } catch let moveError {
            // Copying is a cross-volume fallback, not a generic retry. On a
            // permission, collision, ACL or I/O failure it could otherwise
            // leave a partial destination and obscure the real error.
            guard Self.isCrossDeviceError(moveError) else {
                throw QuarantineError.moveFailed(moveError.localizedDescription)
            }
        }

        do {
            try fm.copyItem(at: source, to: destination)
        } catch {
            try? fm.removeItem(at: destination)
            throw QuarantineError.moveFailed(error.localizedDescription)
        }

        do {
            try fm.removeItem(at: source)
        } catch {
            // Keep the operation on its original side when the delete half of
            // copy-and-remove fails. If rollback itself is refused, both
            // copies survive; duplication is safer than deleting either one.
            try? fm.removeItem(at: destination)
            throw QuarantineError.moveFailed(error.localizedDescription)
        }
    }

    static func isCrossDeviceError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EXDEV) {
            return true
        }
        guard let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error else {
            return false
        }
        return isCrossDeviceError(underlying)
    }
}
