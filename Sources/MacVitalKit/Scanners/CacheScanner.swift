import Foundation

/// Table stakes. Every tool in this category does it; there is nothing to
/// differentiate on, so it stays small and correct.
public struct CacheScanner: Scanner {
    public let category: ScanCategory = .caches

    public init() {}

    public func scan(context: ScanContext, progress: @Sendable (ScanProgress) -> Void) async throws -> [ScanItem] {
        var items: [ScanItem] = []
        let index = InstalledAppIndex.build()

        for (position, rule) in RuleCatalog.caches.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            progress(ScanProgress(
                category: category,
                message: rule.kind,
                fraction: Double(position) / Double(max(RuleCatalog.caches.count, 1))
            ))

            let root = URL(fileURLWithPath: rule.pattern.literalPrefix)
            guard FileWalker.exists(root) else { continue }

            for child in FileWalker.children(of: root) {
                if Task.isCancelled { throw CancellationError() }
                let name = child.lastPathComponent
                guard !RuleCatalog.cacheExclusions.contains(name) else { continue }
                // Developer caches are reported by the developer scanner with
                // much better explanations; do not double-count them.
                guard !isDeveloperCache(name) else { continue }

                guard let measurement = (try? FileWalker.measure(child)),
                      measurement.bytes >= context.options.minimumReportedSize
                else { continue }

                var owner = OwnerHint(bundleIdentifier: name.contains(".") ? name : nil)
                if case .installed(let app) = index.match(residueName: name) {
                    owner.appName = app.name
                }

                items.append(ScanItem(
                    path: ProtectedPaths.normalize(child.path),
                    displayName: owner.appName ?? name,
                    category: .caches,
                    ruleID: rule.id,
                    kindHint: rule.kind,
                    sizeBytes: measurement.bytes,
                    fileCount: measurement.fileCount,
                    isDirectory: true,
                    lastModified: measurement.newestModification,
                    ownerHint: owner,
                    rebuildable: true
                ))
            }
        }
        return items.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private func isDeveloperCache(_ name: String) -> Bool {
        [
            "com.apple.dt.Xcode", "CocoaPods", "Homebrew", "Yarn",
            "org.swift.swiftpm", "pip", "node-gyp", "typescript",
        ].contains(name)
    }
}
