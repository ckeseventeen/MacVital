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
        let candidates = try collectCandidates(context: context)

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
        for (digest, urls) in byHash where urls.count > 1 {
            let ordered = urls.sorted { lhs, rhs in
                let l = FileWalker.attributes(of: lhs).modified ?? .distantFuture
                let r = FileWalker.attributes(of: rhs).modified ?? .distantFuture
                if l != r { return l < r }
                return lhs.path.count < rhs.path.count
            }
            let keeper = ordered[0]
            for duplicate in ordered.dropFirst() {
                let attributes = FileWalker.attributes(of: duplicate)
                items.append(ScanItem(
                    path: ProtectedPaths.normalize(duplicate.path),
                    displayName: duplicate.lastPathComponent,
                    category: .duplicateFiles,
                    ruleID: "file.duplicate",
                    kindHint: "副本，保留 \(PathRedaction.abbreviate(keeper.path))",
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

    private struct Candidate {
        let url: URL
        let size: Int64
    }

    private func collectCandidates(context: ScanContext) throws -> [Candidate] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey]
        var candidates: [Candidate] = []

        for rootPath in context.options.userFileRoots {
            let root = URL(fileURLWithPath: rootPath)
            guard FileWalker.exists(root) else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants, .skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                if Task.isCancelled { throw CancellationError() }
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let size = Int64(values.totalFileAllocatedSize ?? 0)
                guard size >= minimumSize else { continue }
                candidates.append(Candidate(url: url, size: size))
            }
        }
        return candidates
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
