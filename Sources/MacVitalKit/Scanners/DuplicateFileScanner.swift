import Foundation
import CryptoKit

/// Three-phase duplicate detection: group by size, then by a cheap head+tail
/// digest, then by full SHA-256 on whatever survives. Only byte-identical
/// files are ever reported — "looks similar" is not a claim this app makes.
///
/// Within each group the oldest file (by creation, falling back to the
/// shortest path) is the keeper and is never offered for removal.
public struct DuplicateFileScanner: Scanner {
    public let category: ScanCategory = .duplicateFiles

    /// Below this, the disk savings do not justify the read cost.
    private let minimumSize: Int64 = 1_000_000
    private let sampleSize = 64 * 1024

    public init() {}

    public func scan(context: ScanContext, progress: @Sendable (ScanProgress) -> Void) async throws -> [ScanItem] {
        progress(ScanProgress(category: category, message: "建立索引", fraction: 0.1))
        let candidates = try await collectCandidates(context: context)

        // Phase 1 — size. Anything with a unique size cannot have a duplicate.
        var bySize: [Int64: [URL]] = [:]
        for candidate in candidates {
            bySize[candidate.size, default: []].append(candidate.url)
        }
        let sizeGroups = bySize.filter { $0.value.count > 1 }
        progress(ScanProgress(category: category, message: "比对候选", fraction: 0.4))

        // Phase 2 — head+tail sample. Cheap, kills almost all false groups.
        var bySample: [String: [URL]] = [:]
        for (size, urls) in sizeGroups {
            if Task.isCancelled { throw CancellationError() }
            for url in urls {
                guard let digest = sampleDigest(of: url, size: size) else { continue }
                bySample["\(size):\(digest)", default: []].append(url)
            }
        }
        let sampleGroups = bySample.filter { $0.value.count > 1 }
        progress(ScanProgress(category: category, message: "校验内容", fraction: 0.7))

        // Phase 3 — full hash. Only this result is reported as a duplicate.
        var byHash: [String: [URL]] = [:]
        for (_, urls) in sampleGroups {
            if Task.isCancelled { throw CancellationError() }
            for url in urls {
                guard let digest = fullDigest(of: url) else { continue }
                byHash[digest, default: []].append(url)
            }
        }

        var items: [ScanItem] = []
        for (digest, urls) in byHash {
            // Distinct paths only. Two entries for one path — overlapping scan
            // roots, or the same file reached twice — would otherwise make a
            // file a duplicate of itself and offer the only copy for removal.
            //
            // Then distinct *files*, which is not the same question. Two hard
            // links are two paths to one inode: byte-identical by construction,
            // so they always group here, and removing one frees nothing at all
            // while the summary counts its full size. That is the same class of
            // untruth as the old `reclaimedBytes` — the user checks their free
            // space and the number did not move.
            let unique = Self.distinctFiles(Array(Set(urls.map(\.path))).map(URL.init(fileURLWithPath:)))
            guard unique.count > 1 else { continue }

            // Oldest wins, by creation date, exactly as documented. This read
            // `contentModificationDate`, which is a different question with a
            // different answer: copying a file usually preserves its mtime
            // while giving it a fresh birth time, so the two can disagree about
            // which copy is the original — the one thing this must not get
            // wrong, since it decides which file survives.
            let ordered = unique.sorted { lhs, rhs in
                let l = Self.creationDate(of: lhs) ?? .distantFuture
                let r = Self.creationDate(of: rhs) ?? .distantFuture
                if l != r { return l < r }
                return lhs.path.count < rhs.path.count
            }
            let keeper = ordered[0]
            for duplicate in ordered.dropFirst() {
                // Resolved per file, not per group: two copies of the same
                // bytes can sit under different roots.
                guard let rule = RuleCatalog.userFileRule(for: duplicate.path, category: category) else { continue }
                let attributes = FileWalker.attributes(of: duplicate)
                items.append(ScanItem(
                    path: ProtectedPaths.normalize(duplicate.path),
                    displayName: duplicate.lastPathComponent,
                    category: .duplicateFiles,
                    ruleID: rule.id,
                    kindHint: "副本，保留 \(PathRedaction.abbreviate(keeper.path))",
                    // Allocated size here on purpose: this is what the disk
                    // actually hands back, which is the number the summary adds
                    // up. Only the *grouping* has to use logical length.
                    sizeBytes: FileWalker.size(of: duplicate),
                    fileCount: 1,
                    isDirectory: false,
                    lastModified: attributes.modified,
                    lastAccessed: attributes.accessed,
                    groupKey: digest,
                    rebuildable: false
                ))
            }
        }

        progress(ScanProgress(category: category, message: "完成", fraction: 1.0))
        return Array(
            items.sorted { $0.sizeBytes > $1.sizeBytes }
                .prefix(context.options.maxUserFileResults)
        )
    }

    // MARK: - Candidates

    fileprivate struct Candidate {
        let url: URL
        let size: Int64
    }

    /// `.fileSizeKey`, the logical length — not `.totalFileAllocatedSize`.
    ///
    /// Allocated size is block-rounded and includes metadata, which broke this
    /// twice over: byte-identical files whose on-disk footprint differs (HFS
    /// compression, a resource fork, a different volume's block size) never
    /// landed in the same size bucket and were missed outright; and the tail
    /// sample below seeked to `size - sampleSize`, which on a rounded-up size
    /// is past EOF, so the read came back empty and the "head+tail" digest
    /// silently degraded to head-only — throwing away the cheap filter that
    /// keeps the full SHA-256 pass small.
    fileprivate static let sizeKeys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]

    private func collectCandidates(context: ScanContext) async throws -> [Candidate] {
        var candidates: [Candidate] = []

        for rootPath in context.options.userFileRoots {
            let root = URL(fileURLWithPath: rootPath)
            guard FileWalker.exists(root) else { continue }
            // Default-deny applied to configuration: a root no rule describes
            // cannot yield a removable file, so it is not walked.
            guard RuleCatalog.userFileRule(for: rootPath, category: category) != nil else {
                Log.scan.debug("no rule covers \(Log.path(rootPath), privacy: .public); not scanning it")
                continue
            }
            guard let cursor = Cursor(root: root, minimumSize: minimumSize) else { continue }

            // This walk is the longest uninterrupted stretch of the whole scan.
            // Yielding between batches keeps the other scanners in the group
            // moving and lets cancellation land promptly.
            //
            // The walk itself stays synchronous inside `Cursor`:
            // `FileManager.DirectoryEnumerator`'s iterator is `noasync`, and
            // iterating it directly in this function is an error under the
            // Swift 6 language mode.
            while let batch = try cursor.nextBatch() {
                candidates += batch
                await Task.yield()
            }
        }
        return candidates
    }

    /// Walks one root in bounded chunks, synchronously.
    private final class Cursor {
        private let enumerator: FileManager.DirectoryEnumerator
        private let minimumSize: Int64
        private let batchSize = 2_000

        init?(root: URL, minimumSize: Int64) {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: DuplicateFileScanner.sizeKeys,
                options: [.skipsPackageDescendants, .skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else { return nil }
            self.enumerator = enumerator
            self.minimumSize = minimumSize
        }

        /// The next chunk, or nil when the walk is finished.
        func nextBatch() throws -> [Candidate]? {
            var batch: [Candidate] = []
            var visited = 0

            while visited < batchSize {
                if Task.isCancelled { throw CancellationError() }
                guard let url = enumerator.nextObject() as? URL else {
                    return batch.isEmpty ? nil : batch
                }
                visited += 1

                guard let values = try? url.resourceValues(forKeys: Set(DuplicateFileScanner.sizeKeys)) else { continue }
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let size = Int64(values.fileSize ?? 0)
                guard size >= minimumSize else { continue }
                batch.append(Candidate(url: url, size: size))
            }
            return batch
        }
    }

    /// Collapses paths that are names for the same inode, keeping one each.
    ///
    /// Deliberately not a claim about APFS clones. A clone is a separate inode
    /// whose blocks are shared until one side is written, and macOS exposes no
    /// public way to ask how much of that sharing survives — so a cloned copy
    /// is reported, and removing it does return less than its stated size. The
    /// framing above it is at least honest about that: the summary says how
    /// much moved to quarantine, not how much the volume got back.
    static func distinctFiles(_ urls: [URL]) -> [URL] {
        var seen = Set<FileIdentity>()
        var result: [URL] = []
        for url in urls {
            guard let identity = FileIdentity(path: url.path) else {
                // Unreadable: keep it rather than silently dropping a candidate.
                result.append(url)
                continue
            }
            if seen.insert(identity).inserted { result.append(url) }
        }
        return result
    }

    /// Device plus inode — what actually identifies a file on disk, as opposed
    /// to a name that points at one.
    struct FileIdentity: Hashable {
        let device: dev_t
        let inode: ino_t

        init?(path: String) {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            self.device = info.st_dev
            self.inode = info.st_ino
        }
    }

    private static func creationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    // MARK: - Digests

    private func sampleDigest(of url: URL, size: Int64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        guard let head = try? handle.read(upToCount: sampleSize) else { return nil }
        hasher.update(data: head)

        if size > Int64(sampleSize) * 2 {
            let tailOffset = UInt64(size) - UInt64(sampleSize)
            if (try? handle.seek(toOffset: tailOffset)) != nil,
               let tail = try? handle.read(upToCount: sampleSize) {
                hasher.update(data: tail)
            }
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    private func fullDigest(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 4 * 1024 * 1024
        while true {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }
}
