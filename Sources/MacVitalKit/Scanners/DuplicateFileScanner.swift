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
                guard let digest = Self.fullDigest(of: url) else { continue }
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
            let paths = Array(Set(urls.map(\.path))).map(URL.init(fileURLWithPath:))
            guard let plan = Self.plan(group: paths) else { continue }
            let keeper = plan.keeper
            for duplicate in plan.removable {
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
                    duplicateKeeperPath: ProtectedPaths.normalize(keeper.path),
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

    /// Which file of a byte-identical group stays, and which may go.
    ///
    /// Oldest wins, by creation date, exactly as documented. This read
    /// `contentModificationDate`, which is a different question with a
    /// different answer: copying a file usually preserves its mtime while
    /// giving it a fresh birth time, so the two can disagree about which copy
    /// is the original — the one thing this must not get wrong, since it
    /// decides which file survives.
    ///
    /// Sorted before collapsing, so a family of hard links or clones is
    /// represented by its oldest member. Then a file is offered only if
    /// removing it gives space back on its own: one whose blocks another hard
    /// link or a full APFS clone still holds frees nothing, and it was being
    /// offered at full size — Finder's ⌘D makes exactly such a clone.
    static func plan(group urls: [URL]) -> (keeper: URL, removable: [URL])? {
        let ordered = urls.sorted { lhs, rhs in
            let l = creationDate(of: lhs) ?? .distantFuture
            let r = creationDate(of: rhs) ?? .distantFuture
            if l != r { return l < r }
            return lhs.path.count < rhs.path.count
        }
        let unique = distinctFiles(ordered)
        guard unique.count > 1 else { return nil }
        let removable = unique.dropFirst().filter { url in
            guard let storage = StorageInfo(path: url.path) else { return true }
            return !storage.sharesBlocks
        }
        return (unique[0], Array(removable))
    }

    /// Collapses paths that hold the same data, keeping the first of each.
    ///
    /// Hard links are one inode; pure APFS clones are separate inodes over one
    /// data stream, and the clone ID says so. This used to stop at inodes on
    /// the belief that macOS had no public way to see clone sharing —
    /// `ATTR_CMNEXT_CLONEID` is exactly that. (A clone that has since been
    /// written to gets a stream of its own, and so counts as its own file.)
    static func distinctFiles(_ urls: [URL]) -> [URL] {
        var seen = Set<StorageIdentity>()
        var result: [URL] = []
        for url in urls {
            guard let storage = StorageInfo(path: url.path) else {
                // Unreadable: keep it rather than silently dropping a candidate.
                result.append(url)
                continue
            }
            if seen.insert(storage.identity).inserted { result.append(url) }
        }
        return result
    }

    /// Device plus data stream: the clone ID where the volume tracks clones,
    /// else the inode. Two paths with the same identity are one set of blocks.
    struct StorageIdentity: Hashable {
        let device: dev_t
        let stream: UInt64
    }

    struct StorageInfo {
        let identity: StorageIdentity
        /// Another name or a full clone holds these blocks too, so removing
        /// this path alone returns nothing to the volume.
        let sharesBlocks: Bool

        init?(path: String) {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            let clone = Self.cloneAttributes(of: path)
            identity = StorageIdentity(device: info.st_dev, stream: clone?.id ?? UInt64(info.st_ino))
            sharesBlocks = info.st_nlink > 1 || (clone?.familySize ?? 1) > 1
        }

        /// `ATTR_CMNEXT_CLONEID` and `ATTR_CMNEXT_CLONE_REFCNT` — the refcount
        /// counts every full clone including this file. `nil` where the volume
        /// does not report them.
        private static func cloneAttributes(of path: String) -> (id: UInt64, familySize: UInt32)? {
            var request = attrlist()
            request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            request.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT)

            // u_int32_t length, attribute_set_t returned, u_int64_t clone ID,
            // u_int32_t clone refcount — packed, in that order.
            var buffer = [UInt8](repeating: 0, count: 64)
            let status = buffer.withUnsafeMutableBytes { raw in
                getattrlist(path, &request, raw.baseAddress, raw.count,
                            UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
            }
            guard status == 0 else { return nil }
            return buffer.withUnsafeBytes { raw in
                let returned = raw.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
                let wanted = attrgroup_t(ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT)
                guard returned.forkattr & wanted == wanted else { return nil }
                let offset = 4 + MemoryLayout<attribute_set_t>.size
                let id = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                let familySize = raw.loadUnaligned(fromByteOffset: offset + 8, as: UInt32.self)
                return id == 0 ? nil : (id, familySize)
            }
        }
    }

    /// Device plus inode — what actually identifies a file on disk, as opposed
    /// to a name that points at one.
    struct FileIdentity: Hashable {
        let device: dev_t
        let inode: ino_t

        init(device: dev_t, inode: ino_t) {
            self.device = device
            self.inode = inode
        }

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
            guard (try? handle.seek(toOffset: tailOffset)) != nil,
                  let tail = try? handle.read(upToCount: sampleSize),
                  tail.count == sampleSize
            else { return nil }
            hasher.update(data: tail)
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    static func fullDigest(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 4 * 1024 * 1024
        do {
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            // A read error is not EOF. Hashing only the readable prefix can
            // make two damaged or concurrently-mutated files look identical.
            return nil
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Revalidates the destructive claim at execution time. Both the offered
    /// duplicate and the elected keeper must still be distinct regular files,
    /// unchanged while hashing, and equal to the scan-time full digest.
    static func isStillDuplicate(_ item: ScanItem) -> Bool {
        guard item.category == .duplicateFiles,
              let keeperPath = item.duplicateKeeperPath,
              let expectedDigest = item.groupKey,
              item.path != keeperPath,
              let candidateBefore = FileSnapshot(path: item.path),
              let keeperBefore = FileSnapshot(path: keeperPath),
              candidateBefore.isRegular,
              keeperBefore.isRegular,
              candidateBefore.identity != keeperBefore.identity,
              candidateBefore.size == keeperBefore.size,
              fullDigest(of: URL(fileURLWithPath: item.path)) == expectedDigest,
              fullDigest(of: URL(fileURLWithPath: keeperPath)) == expectedDigest,
              let candidateAfter = FileSnapshot(path: item.path),
              let keeperAfter = FileSnapshot(path: keeperPath),
              candidateBefore == candidateAfter,
              keeperBefore == keeperAfter
        else { return false }
        return true
    }

    private struct FileSnapshot: Equatable {
        let identity: FileIdentity
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let isRegular: Bool

        init?(path: String) {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            identity = FileIdentity(device: info.st_dev, inode: info.st_ino)
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
            isRegular = (info.st_mode & S_IFMT) == S_IFREG
        }
    }
}
