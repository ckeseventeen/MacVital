import Foundation

/// Individual files over a threshold. Nothing here is ever pre-selected —
/// whether a 4 GB video matters is not something a rule or a model can know.
public struct LargeFileScanner: Scanner {
    public let category: ScanCategory = .largeFiles

    public init() {}

    public func scan(context: ScanContext, progress: @Sendable (ScanProgress) -> Void) async throws -> [ScanItem] {
        var found: [ScanItem] = []
        let roots = context.options.userFileRoots
            .map(URL.init(fileURLWithPath:))
            .filter { FileWalker.exists($0) }

        for (position, root) in roots.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            progress(ScanProgress(
                category: category,
                message: PathRedaction.abbreviate(root.path),
                fraction: Double(position) / Double(max(roots.count, 1))
            ))
            found += try scanRoot(root, context: context)
        }

        return Array(
            found.sorted { $0.sizeBytes > $1.sizeBytes }
                .prefix(context.options.maxUserFileResults)
        )
    }

    private func scanRoot(_ root: URL, context: ScanContext) throws -> [ScanItem] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
            .totalFileAllocatedSizeKey, .contentModificationDateKey, .contentAccessDateKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var items: [ScanItem] = []
        for case let url as URL in enumerator {
            if Task.isCancelled { throw CancellationError() }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let bytes = Int64(values.totalFileAllocatedSize ?? 0)
            guard bytes >= context.options.largeFileThreshold else { continue }

            items.append(ScanItem(
                path: ProtectedPaths.normalize(url.path),
                displayName: url.lastPathComponent,
                category: .largeFiles,
                ruleID: "file.large",
                kindHint: url.pathExtension.isEmpty ? "文件" : url.pathExtension.uppercased(),
                sizeBytes: bytes,
                fileCount: 1,
                isDirectory: false,
                lastModified: values.contentModificationDate,
                lastAccessed: values.contentAccessDate,
                rebuildable: false
            ))
        }
        return items
    }
}
