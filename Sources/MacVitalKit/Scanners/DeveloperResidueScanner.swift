import Foundation

/// The flagship scanner. Two halves:
///
///  * Fixed-location artifacts (DerivedData, simulator caches, package-manager
///    caches) — expand the rule's pattern and measure what is there.
///  * Project artifacts (node_modules, Pods, target, .build) — search the
///    user's project roots by name, then look for the lock file that proves
///    the directory can be rebuilt.
public struct DeveloperResidueScanner: Scanner {
    public let category: ScanCategory = .developerResidue

    public init() {}

    public func scan(context: ScanContext, progress: @Sendable (ScanProgress) -> Void) async throws -> [ScanItem] {
        var items: [ScanItem] = []
        items += try scanFixedLocations(context: context, progress: progress)
        items += try await scanProjectArtifacts(context: context, progress: progress)
        return items.filter { $0.sizeBytes >= context.options.minimumReportedSize }
    }

    // MARK: - Fixed locations

    private func scanFixedLocations(
        context: ScanContext,
        progress: @Sendable (ScanProgress) -> Void
    ) throws -> [ScanItem] {
        let rules = RuleCatalog.developerResidue
        var items: [ScanItem] = []

        for (index, rule) in rules.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            progress(ScanProgress(
                category: category,
                message: rule.kind,
                fraction: Double(index) / Double(max(rules.count, 1)) * 0.5
            ))

            for url in expand(rule: rule) {
                guard let item = makeItem(url: url, rule: rule) else { continue }
                items.append(item)
            }
        }
        return items
    }

    /// Turn a rule pattern into concrete paths. Only the shapes actually used
    /// in the catalog are handled: `prefix/*`, `prefix/**`, and literals.
    private func expand(rule: CleanupRule) -> [URL] {
        let prefix = URL(fileURLWithPath: rule.pattern.literalPrefix)
        guard FileWalker.exists(prefix) else { return [] }

        if rule.pattern.isLiteral {
            return [prefix]
        }
        if rule.pattern.raw.hasSuffix("/**") {
            // Treat the whole subtree as one unit — a package-manager cache is
            // meaningful as a whole, not file by file.
            return [prefix]
        }
        // `prefix/*` — each direct child is its own unit so the user can keep
        // the DerivedData for the project they are working on.
        return FileWalker.children(of: prefix).filter { rule.pattern.matches(ProtectedPaths.normalize($0.path)) }
    }

    private func makeItem(url: URL, rule: CleanupRule) -> ScanItem? {
        let attributes = FileWalker.attributes(of: url)
        let measurement = attributes.isDirectory
            ? (try? FileWalker.measure(url))
            : nil
        let bytes = measurement?.bytes ?? FileWalker.size(of: url)
        guard bytes > 0 else { return nil }

        return ScanItem(
            path: ProtectedPaths.normalize(url.path),
            displayName: displayName(for: url, rule: rule),
            category: .developerResidue,
            ruleID: rule.id,
            kindHint: rule.kind,
            sizeBytes: bytes,
            fileCount: measurement?.fileCount ?? 1,
            isDirectory: attributes.isDirectory,
            lastModified: measurement?.newestModification ?? attributes.modified,
            lastAccessed: attributes.accessed,
            rebuildable: rule.rebuildable
        )
    }

    private func displayName(for url: URL, rule: CleanupRule) -> String {
        let name = url.lastPathComponent
        // DerivedData directories are named `MyApp-abcdefghijklmnop`; the hash
        // is noise, the project name is the useful part.
        if rule.id == "dev.xcode.derivedData", let dash = name.range(of: "-", options: .backwards) {
            let candidate = String(name[..<dash.lowerBound])
            if !candidate.isEmpty { return candidate }
        }
        if rule.pattern.raw.hasSuffix("/**") { return rule.kind }
        return name
    }

    // MARK: - Project artifacts

    private func scanProjectArtifacts(
        context: ScanContext,
        progress: @Sendable (ScanProgress) -> Void
    ) async throws -> [ScanItem] {
        let rules = RuleCatalog.projectArtifacts
        let rulesByName = Dictionary(
            rules.compactMap { rule in rule.projectArtifactName.map { ($0, rule) } },
            uniquingKeysWith: { first, _ in first }
        )
        let names = Set(rulesByName.keys)

        var items: [ScanItem] = []
        let roots = context.options.projectRoots
            .map { URL(fileURLWithPath: $0) }
            .filter { FileWalker.exists($0) }

        for (index, root) in roots.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            progress(ScanProgress(
                category: category,
                message: PathRedaction.abbreviate(root.path),
                fraction: 0.5 + Double(index) / Double(max(roots.count, 1)) * 0.5
            ))

            let found = try FileWalker.findDirectories(
                named: names,
                under: root,
                maxDepth: context.options.projectSearchDepth
            )

            for directory in found {
                guard let rule = rulesByName[directory.lastPathComponent] else { continue }
                guard let measurement = try? FileWalker.measure(directory), measurement.bytes > 0 else { continue }

                let projectDirectory = directory.deletingLastPathComponent()
                let evidence = rule.rebuildEvidence.first {
                    FileWalker.exists(projectDirectory.appendingPathComponent($0))
                }

                items.append(ScanItem(
                    path: ProtectedPaths.normalize(directory.path),
                    displayName: "\(projectDirectory.lastPathComponent)/\(directory.lastPathComponent)",
                    category: .developerResidue,
                    ruleID: rule.id,
                    kindHint: rule.kind,
                    sizeBytes: measurement.bytes,
                    fileCount: measurement.fileCount,
                    isDirectory: true,
                    lastModified: measurement.newestModification,
                    groupKey: projectDirectory.path,
                    ownerHint: OwnerHint(projectPath: projectDirectory.path),
                    // Only claim rebuildability when we can point at the file
                    // that makes it true. "Probably reinstallable" is not good
                    // enough to pre-tick a checkbox.
                    rebuildable: evidence != nil
                ))
            }
        }
        return items
    }
}
