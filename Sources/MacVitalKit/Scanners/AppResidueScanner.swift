import Foundation

/// Finds files left behind by apps that are no longer installed.
///
/// The deterministic half is bundle-ID matching, which is what every tool in
/// this category does and which misses a lot: renamed helpers, vendor-shared
/// support directories, config files named after the product rather than the
/// bundle. Those land in `needsAttribution` and get handed to the AI layer,
/// which reads the filename, a directory listing and the top-level plist keys
/// and decides who they belong to.
public struct AppResidueScanner: Scanner {
    public let category: ScanCategory = .appResidue

    /// A cheap first pass. Deliberately not the only one: a name-based deny
    /// list can never be complete, which is why `/Library` paths also get
    /// checked against the installer receipt database (see `makeItem`).
    private static let systemPrefixes = [
        "com.apple.", "group.com.apple.", "org.swift.", "com.macvital.",
    ]
    private static let systemNames: Set<String> = [
        "MobileSync", "CrashReporter", "Apple", "CloudDocs", "iCloud",
        "com.apple.sharedfilelist", "AddressBook", "Knowledge", "Screen Time",
        // Generic shared directories that belong to no single app. A directory
        // literally named `Caches` under Application Support is a bucket that
        // several installed apps drop updater state into — calling it the
        // residue of an uninstalled app is simply wrong, whatever its size.
        "Caches", "Cache", "Logs", "Temp", "tmp", "Updater", "Updates",
    ]

    public init() {}

    public func scan(context: ScanContext, progress: @Sendable (ScanProgress) -> Void) async throws -> [ScanItem] {
        let index = InstalledAppIndex.build()
        let rules = RuleCatalog.appResidue
        var items: [ScanItem] = []

        for (position, rule) in rules.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            progress(ScanProgress(
                category: category,
                message: rule.kind,
                fraction: Double(position) / Double(max(rules.count, 1))
            ))

            let root = URL(fileURLWithPath: rule.pattern.literalPrefix)
            guard FileWalker.exists(root) else { continue }

            for child in FileWalker.children(of: root) {
                if Task.isCancelled { throw CancellationError() }
                let normalized = ProtectedPaths.normalize(child.path)
                guard rule.pattern.matches(normalized) else { continue }

                let name = child.lastPathComponent
                guard !isSystemOwned(name) else { continue }

                let match = index.match(residueName: name)
                guard let item = makeItem(url: child, rule: rule, match: match, index: index) else { continue }
                items.append(item)
            }
        }

        return items
            .filter { $0.sizeBytes > 0 }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private func isSystemOwned(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if Self.systemPrefixes.contains(where: { lowered.hasPrefix($0) }) { return true }
        if Self.systemNames.contains(name) { return true }
        return false
    }

    private func makeItem(
        url: URL,
        rule: CleanupRule,
        match: InstalledAppIndex.Match,
        index: InstalledAppIndex
    ) -> ScanItem? {
        // An installed app's files are not residue. Stop here.
        if case .installed = match { return nil }
        if case .nameSimilar = match { return nil }

        // Neither are the operating system's. Under `/Library` "matches no
        // installed app" is not evidence of residue, because macOS installs
        // there and belongs to no app — `/Library/Application Support/BTServer`
        // is 46 Bluetooth country-code plists from a system update, and it was
        // being offered for removal. Asked last, and only for absolute
        // `/Library`, because the answer costs a subprocess.
        let path = ProtectedPaths.normalize(url.path)
        if path.hasPrefix("/Library/"), PackageOwnership.isSystemProvided(path) {
            Log.scan.debug("skipping system-provided \(Log.path(path), privacy: .public)")
            return nil
        }

        let attributes = FileWalker.attributes(of: url)
        let measurement = attributes.isDirectory ? (try? FileWalker.measure(url)) : nil
        let bytes = measurement?.bytes ?? FileWalker.size(of: url)
        guard bytes > 0 else { return nil }

        let token = InstalledAppIndex.identifierToken(from: url.lastPathComponent)
        var owner = OwnerHint(bundleIdentifier: token.contains(".") ? token : nil)

        // `.vendorInstalled` is the interesting case: the vendor is still here
        // but this identifier is not. Could be a stale helper worth removing,
        // could be a live shared component. Flag it, do not guess.
        var kind = rule.kind
        if case .vendorInstalled(let vendor) = match {
            owner.appName = index.app(withBundleIdentifier: vendor)?.name
            kind = "\(rule.kind)（同厂商仍在使用）"
        }

        return ScanItem(
            path: ProtectedPaths.normalize(url.path),
            displayName: url.lastPathComponent,
            category: .appResidue,
            ruleID: rule.id,
            kindHint: kind,
            sizeBytes: bytes,
            fileCount: measurement?.fileCount ?? 1,
            isDirectory: attributes.isDirectory,
            lastModified: measurement?.newestModification ?? attributes.modified,
            lastAccessed: attributes.accessed,
            groupKey: owner.bundleIdentifier,
            ownerHint: owner,
            rebuildable: false
        )
    }
}
