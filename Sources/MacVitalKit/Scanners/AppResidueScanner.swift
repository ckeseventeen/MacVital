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
        // The system's own crash-report machinery. `~/Library/Logs/
        // DiagnosticReports` is where macOS writes every crash on the machine,
        // and `CrashReporter` holds its per-process state — an audit found both
        // being offered as the leftovers of an uninstalled app.
        "DiagnosticReports", "CrashReporter",
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
            // Some rules exist to give `AppUninstallPlanner` coverage of a
            // directory that belongs to one particular app — and several of
            // those directories belong to Apple. Sweeping their *contents* as
            // residue is a category error the per-child name filter cannot
            // catch, because the give-away is the parent: an audit found the
            // children of `~/Library/Caches/com.apple.helpd` offered one by
            // one, including `Cache.db`, `Cache.db-wal` and `Cache.db-shm` as
            // three separate rows — removing any one of which corrupts the
            // other two.
            guard !isSystemOwned(root.lastPathComponent) else {
                Log.scan.debug("not sweeping system-owned root \(Log.path(root.path), privacy: .public)")
                continue
            }

            for child in FileWalker.children(of: root) {
                if Task.isCancelled { throw CancellationError() }
                let normalized = ProtectedPaths.normalize(child.path)
                guard rule.pattern.matches(normalized) else { continue }

                let name = child.lastPathComponent
                guard !isSystemOwned(name) else { continue }
                guard isAttributable(name: name, rule: rule) else {
                    Log.scan.debug("no basis to attribute \(Log.path(child.path), privacy: .public)")
                    continue
                }

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
        // Namespaces macOS occupies under someone else's reverse-DNS name.
        // The prefix list above only knows Apple's own; the OS also ships CUPS,
        // Apache, cron, OpenLDAP and net-snmp under their upstream identifiers.
        // `/Library/Preferences/org.cups.printers.plist` — every printer the
        // user has configured — was being offered for removal because of it,
        // and none of the existing guards could see it: not an app, no
        // `com.apple.` prefix, and no package receipt either, because `cupsd`
        // writes the file at runtime rather than an installer placing it.
        if SystemDomainIndex.isSystemDomain(InstalledAppIndex.identifierToken(from: name)) { return true }
        return false
    }

    /// Rules whose directory the OS shares with applications, and where the
    /// filename is the *only* attribution available.
    ///
    /// `~/Library/Preferences` is the case that matters: macOS keeps its own
    /// domains there alongside every app's, and plenty of them carry no
    /// `com.apple.` prefix — `ContextStoreAgent.plist` and
    /// `TokenBucketRateLimiter.plist` were both offered for removal as the
    /// leftovers of an uninstalled app. A name-based deny list can never be
    /// complete, so the requirement is structural instead.
    static let identifierKeyedRules: Set<String> = [
        "residue.preferences", "residue.preferencesByHost",
        // Everything under `/Library`, for the same reason and then some.
        //
        // That directory is shared by the OS and by every installer on the
        // machine, and most of what sits in `/Library/Preferences` is not an
        // app's file at all: `OpenDirectory`, `SystemConfiguration`,
        // `DirectoryService`, `Audio`, `Logging` and `Xsan` are directories
        // macOS maintains itself. None of them carries a package receipt —
        // daemons write them at runtime — so `PackageOwnership` cannot see
        // them either, and an audit found `OpenDirectory` and
        // `/Library/Application Support/VMware` reaching the user, saved only
        // by an unrelated permissions check.
        //
        // Third-party software in these directories is named after its bundle
        // identifier without exception: `com.docker.vmnetd`,
        // `com.omiga.bitboo.ProxyConfigHelper`,
        // `io.github.clash-verge-rev.clash-verge-rev.service`. Requiring that
        // shape costs nothing real, and the trade is one-directional — under
        // `/Library` a missed cleanup costs disk space, while a false positive
        // is a *privileged* removal of something the system is using.
        "residue.systemPreferences", "residue.systemApplicationSupport",
        "residue.systemCaches", "residue.privilegedHelpers",
        "residue.systemLaunchAgents", "residue.systemLaunchDaemons",
    ]

    /// Whether there is any basis at all for claiming an app owned this.
    ///
    /// Two structural refusals, both erring toward "leave it alone" — an
    /// over-cautious scanner costs a missed suggestion, an over-eager one costs
    /// the user's settings:
    ///
    ///  * a dotfile in `~/Library` is system state, not an app's residue.
    ///    `.GlobalPreferences.plist` is the whole system's locale, language and
    ///    interface style, and it was being proposed for deletion.
    ///  * in a directory the OS shares with apps, a name that is not shaped
    ///    like a bundle identifier attributes to nothing.
    private func isAttributable(name: String, rule: CleanupRule) -> Bool {
        if name.hasPrefix(".") { return false }
        guard Self.identifierKeyedRules.contains(rule.id) else { return true }
        return InstalledAppIndex.looksLikeBundleIdentifier(
            InstalledAppIndex.identifierToken(from: name)
        )
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

        let path = ProtectedPaths.normalize(url.path)

        // A launchd job whose program lives inside an app that is still
        // installed is not residue, whatever its filename suggests. Filename
        // attribution is close to useless here: `com.netease.uuremote.daemon.plist`
        // matched nothing while UURemote.app sat in /Applications with its
        // daemon running.
        //
        // Note how narrow this is. The first version asked only whether the
        // target file existed, and that hid three genuinely orphaned daemons:
        // uninstalling an app leaves its privileged helper in
        // /Library/PrivilegedHelperTools, so the daemon points at a real file
        // forever. Docker, Clash Verge and Bitboo were all gone from
        // /Applications while their helpers sat there untouched.
        if url.pathExtension == "plist",
           LaunchItemAttribution.belongsToAnInstalledApp(plist: path) {
            Log.scan.debug("skipping live launch item \(Log.path(path), privacy: .public)")
            return nil
        }

        // Same argument from the other end: a privileged helper is named after
        // its vendor, so nothing places it either — but a *live* daemon that
        // launches it does, and removing the helper would break that daemon.
        // Only live ones count, or an orphaned daemon and its orphaned helper
        // would vouch for each other indefinitely.
        if LaunchItemAttribution.isReferencedByALiveLaunchItem(path) {
            Log.scan.debug("skipping referenced helper \(Log.path(path), privacy: .public)")
            return nil
        }

        // Neither is the operating system's own. Under `/Library` "matches no
        // installed app" is not evidence of residue, because macOS installs
        // there and belongs to no app — `/Library/Application Support/BTServer`
        // is 46 Bluetooth country-code plists from a system update, and it was
        // being offered for removal. Asked last, and only for absolute
        // `/Library`, because the answer costs a subprocess.
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
