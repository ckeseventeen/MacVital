import Foundation

/// Builds the removal plan for one app the user has named.
///
/// The difference from `AppResidueScanner` is only in who starts the sentence.
/// The residue scanner sweeps a directory and has to *prove* the owning app is
/// gone before it dares propose anything — attribution is the hard part and
/// getting it wrong deletes live data. Here the user has already said "remove
/// this app", so attribution is given and the job is coverage: find the pieces
/// an app scatters across `~/Library` that dragging the bundle to the Trash
/// leaves behind.
///
/// Every path produced is tagged with a rule that already exists in the
/// catalog, so `RuleEngine` re-derives permission from the same allowlist the
/// rest of the app uses. The planner grants nothing; it proposes.
public struct AppUninstallPlanner: Sendable {
    /// Where a candidate path came from, so the UI can group and explain.
    public enum Kind: String, Sendable {
        case bundle
        case support
        case cache
        case preference
        case container
        case state
        case launchItem
        case log
        case receipt

        public var title: String {
            switch self {
            case .bundle: return "程序本体"
            case .support: return "应用数据"
            case .cache: return "缓存"
            case .preference: return "偏好设置"
            case .container: return "沙盒容器"
            case .state: return "窗口与网络状态"
            case .launchItem: return "后台启动项"
            case .log: return "日志"
            case .receipt: return "安装回执"
            }
        }

        /// Whether removing this loses something the user might want back.
        /// Drives which rows the sheet pre-ticks.
        public var carriesUserData: Bool {
            switch self {
            case .container, .support: return true
            case .bundle, .cache, .preference, .state, .launchItem, .log, .receipt: return false
            }
        }
    }

    public struct Candidate: Identifiable, Sendable {
        public let item: ScanItem
        public let kind: Kind
        public var id: UUID { item.id }
    }

    private let home: String
    /// Not stored: `FileManager` is not `Sendable`, and this type is. The
    /// shared instance is safe to reach for per call.
    private var fileManager: FileManager { .default }

    public init(home: String = PathRedaction.home) {
        self.home = home
    }

    // MARK: - Plan

    public func plan(for app: InstalledAppIndex.App) -> [Candidate] {
        var candidates: [Candidate] = []
        var seen = Set<String>()

        func add(_ path: String, kind: Kind, ruleID: String) {
            let normalized = ProtectedPaths.normalize(path)
            guard seen.insert(normalized).inserted else { return }
            guard fileManager.fileExists(atPath: normalized) else { return }
            guard let item = makeItem(path: normalized, kind: kind, ruleID: ruleID, app: app) else { return }
            candidates.append(Candidate(item: item, kind: kind))
        }

        // 1. The bundle itself.
        let bundlePath = ProtectedPaths.normalize(app.path)
        add(bundlePath, kind: .bundle,
            ruleID: bundlePath.hasPrefix("\(home)/") ? "uninstall.userAppBundle" : "uninstall.appBundle")

        // 2. Everything keyed on the bundle identifier.
        //
        // Every one of these is a *prefix* search, not an exact path. An app
        // does not occupy one directory per location: it occupies its own
        // identifier plus one per extension — `com.acme.App.FinderSync`,
        // `com.acme.App.WidgetExtension`, `com.acme.App.helper` — and the
        // sandbox creates a container and a scripts directory for each of
        // them. Measured against real apps, exact matching found roughly a
        // quarter of what was actually on disk; the rest was extensions.
        let id = app.bundleIdentifier
        let identifierLocations: [(String, Kind, String)] = [
            ("\(home)/Library/Application Support",       .support,    "residue.applicationSupport"),
            ("\(home)/Library/Caches",                    .cache,      "cache.userCaches"),
            ("\(home)/Library/Preferences",               .preference, "residue.preferences"),
            ("\(home)/Library/Preferences/ByHost",        .preference, "residue.preferencesByHost"),
            ("\(home)/Library/Containers",                .container,  "residue.containers"),
            ("\(home)/Library/Group Containers",          .container,  "residue.groupContainers"),
            ("\(home)/Library/Application Scripts",       .state,      "residue.applicationScripts"),
            ("\(home)/Library/Saved Application State",   .state,      "residue.savedState"),
            ("\(home)/Library/HTTPStorages",              .state,      "residue.httpStorages"),
            ("\(home)/Library/WebKit",                    .state,      "residue.webkit"),
            ("\(home)/Library/Logs",                      .log,        "residue.logs"),
            ("\(home)/Library/LaunchAgents",              .launchItem, "residue.launchAgents"),
            // Added after comparing coverage against AppCleaner and CleanMyMac
            // on a real machine. Every one of these is keyed on the bundle
            // identifier the same way the block above is; leaving them out is
            // why "卸载干净" was not true.
            ("\(home)/Library/Cookies",                   .state,      "residue.cookies"),
            ("\(home)/Library/Autosave Information",      .state,      "residue.autosave"),
            ("\(home)/Library/Caches/com.apple.helpd",    .cache,      "residue.helpCache"),
            // Root-owned. The engine marks these `allowWithPrivilege` itself.
            ("/Library/LaunchAgents",                     .launchItem, "residue.systemLaunchAgents"),
            ("/Library/LaunchDaemons",                    .launchItem, "residue.systemLaunchDaemons"),
            ("/Library/PrivilegedHelperTools",            .launchItem, "residue.privilegedHelpers"),
            ("/Library/Application Support",              .support,    "residue.systemApplicationSupport"),
            ("/Library/Caches",                           .cache,      "residue.systemCaches"),
            ("/Library/Preferences",                      .preference, "residue.systemPreferences"),
            // Installer receipts. Reachable only because `ProtectedPaths`
            // exempts exactly this directory from the /private/var/db deny.
            ("/private/var/db/receipts",                  .receipt,    "uninstall.installerReceipt"),
        ]
        for (directory, kind, ruleID) in identifierLocations {
            addMatching(directory, identifier: id, kind: kind, ruleID: ruleID,
                        into: &candidates, seen: &seen, app: app)
        }

        // 3. Name-keyed directories. Plenty of apps ignore the identifier
        //    convention and use their display name — but a bare name is a much
        //    weaker signal than an identifier, so this only fires on an exact
        //    match against a name we already know belongs to this app, never on
        //    a prefix.
        for name in nameKeys(for: app) {
            add("\(home)/Library/Application Support/\(name)", kind: .support, ruleID: "residue.applicationSupport")
            add("\(home)/Library/Caches/\(name)", kind: .cache, ruleID: "cache.userCaches")
            add("\(home)/Library/Logs/\(name)", kind: .log, ruleID: "residue.logs")
        }

        // 4. Crash logs. These are named `<DisplayName>_<HardwareUUID>.plist`,
        //    so neither the identifier match nor an exact name match finds
        //    them — it has to be a name prefix ending at the underscore.
        addCrashReports(app: app, into: &candidates, seen: &seen)

        // 5. Plug-in style bundles. Their directory names are product names,
        //    not identifiers, so guessing from the filename would be exactly
        //    the loose matching this planner avoids everywhere else. Read each
        //    bundle's own CFBundleIdentifier instead and match that.
        for directory in Self.pluginDirectories(home: home) {
            addBundlesIdentifying(directory, identifier: id, kind: .state,
                                 ruleID: "residue.pluginBundles",
                                 into: &candidates, seen: &seen, app: app)
        }

        // 6. Sandbox containers macOS named with a UUID rather than the bundle
        //    identifier. Nothing about the directory name reveals the owner;
        //    the container's own metadata does.
        addUUIDContainers(identifier: id, into: &candidates, seen: &seen, app: app)

        return candidates.sorted { $0.item.sizeBytes > $1.item.sizeBytes }
    }

    // MARK: - Crash reports

    private func addCrashReports(
        app: InstalledAppIndex.App,
        into candidates: inout [Candidate],
        seen: inout Set<String>
    ) {
        let root = URL(fileURLWithPath: "\(home)/Library/Application Support/CrashReporter")
        guard fileManager.fileExists(atPath: root.path) else { return }
        let keys = nameKeys(for: app).map { $0.lowercased() }
        guard !keys.isEmpty else { return }

        for child in FileWalker.children(of: root) {
            let name = child.lastPathComponent
            // `Claude_F73D….plist` -> `Claude`. Anchored at the underscore so
            // `Codex` never claims `CodexHelper_….plist`.
            guard let underscore = name.lastIndex(of: "_") else { continue }
            let stem = String(name[name.startIndex..<underscore]).lowercased()
            guard keys.contains(stem) else { continue }

            let normalized = ProtectedPaths.normalize(child.path)
            guard seen.insert(normalized).inserted else { continue }
            guard let item = makeItem(path: normalized, kind: .log, ruleID: "residue.crashReports", app: app) else { continue }
            candidates.append(Candidate(item: item, kind: .log))
        }
    }

    // MARK: - Plug-in bundles

    static func pluginDirectories(home: String) -> [String] {
        [
            "\(home)/Library/Services",
            "\(home)/Library/QuickLook",
            "\(home)/Library/Internet Plug-Ins",
            "\(home)/Library/PreferencePanes",
            "\(home)/Library/Screen Savers",
            "\(home)/Library/Widgets",
            "\(home)/Library/Audio/Plug-Ins/Components",
            "\(home)/Library/Audio/Plug-Ins/HAL",
            "\(home)/Library/Audio/Plug-Ins/VST",
            "\(home)/Library/Audio/Plug-Ins/VST3",
            "\(home)/Library/Spotlight",
            "\(home)/Library/Mail/Bundles",
        ]
    }

    private func addBundlesIdentifying(
        _ directory: String,
        identifier: String,
        kind: Kind,
        ruleID: String,
        into candidates: inout [Candidate],
        seen: inout Set<String>,
        app: InstalledAppIndex.App
    ) {
        let root = URL(fileURLWithPath: directory)
        guard fileManager.fileExists(atPath: root.path) else { return }

        for child in FileWalker.children(of: root) {
            guard let bundleID = Self.bundleIdentifier(at: child) else { continue }
            guard Self.name(bundleID, belongsTo: identifier) else { continue }
            let normalized = ProtectedPaths.normalize(child.path)
            guard seen.insert(normalized).inserted else { continue }
            guard let item = makeItem(path: normalized, kind: kind, ruleID: ruleID, app: app) else { continue }
            candidates.append(Candidate(item: item, kind: kind))
        }
    }

    static func bundleIdentifier(at url: URL) -> String? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any]
        else { return nil }
        return dictionary["CFBundleIdentifier"] as? String
    }

    // MARK: - UUID containers

    /// macOS does not always name a sandbox container after its owner. When it
    /// does not, the only link back is `MCMMetadataIdentifier` inside the
    /// container's own metadata plist — which is why a UUID container survived
    /// an uninstall and then sat in quarantine as an unattributable blob.
    private func addUUIDContainers(
        identifier: String,
        into candidates: inout [Candidate],
        seen: inout Set<String>,
        app: InstalledAppIndex.App
    ) {
        let root = URL(fileURLWithPath: "\(home)/Library/Containers")
        guard fileManager.fileExists(atPath: root.path) else { return }

        for child in FileWalker.children(of: root) {
            // Only the ones the identifier match cannot already reach.
            guard UUID(uuidString: child.lastPathComponent) != nil else { continue }
            guard let owner = Self.containerOwner(at: child) else { continue }
            guard Self.name(owner, belongsTo: identifier) else { continue }

            let normalized = ProtectedPaths.normalize(child.path)
            guard seen.insert(normalized).inserted else { continue }
            guard let item = makeItem(path: normalized, kind: .container, ruleID: "residue.containers", app: app) else { continue }
            candidates.append(Candidate(item: item, kind: .container))
        }
    }

    static func containerOwner(at container: URL) -> String? {
        let plist = container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any]
        else { return nil }
        return dictionary["MCMMetadataIdentifier"] as? String
    }

    // MARK: - Helpers

    /// Names this app is plausibly filed under: the display name (localized)
    /// and the bundle's own filename on disk (not localized). Deliberately no
    /// vendor token — `Google` would pull in every Google app's shared data
    /// while the user is only removing one of them.
    private func nameKeys(for app: InstalledAppIndex.App) -> [String] {
        var keys: [String] = []
        let filename = URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent
        for candidate in [app.name, filename] where candidate.count >= 3 {
            if !keys.contains(candidate) { keys.append(candidate) }
        }
        return keys
    }

    private func addMatching(
        _ directory: String,
        identifier: String,
        kind: Kind,
        ruleID: String,
        into candidates: inout [Candidate],
        seen: inout Set<String>,
        app: InstalledAppIndex.App
    ) {
        let root = URL(fileURLWithPath: directory)
        guard fileManager.fileExists(atPath: root.path) else { return }
        for child in FileWalker.children(of: root) {
            guard Self.name(child.lastPathComponent, belongsTo: identifier) else { continue }
            let normalized = ProtectedPaths.normalize(child.path)
            guard seen.insert(normalized).inserted else { continue }
            guard let item = makeItem(path: normalized, kind: kind, ruleID: ruleID, app: app) else { continue }
            candidates.append(Candidate(item: item, kind: kind))
        }
    }

    /// Whether a directory entry belongs to this bundle identifier.
    ///
    /// Three accepted shapes, each anchored at a component boundary so
    /// `com.acme.Editor` never matches `com.acme.EditorPro`:
    ///
    ///   * the identifier itself, with or without a file extension,
    ///   * something hanging off it — `com.acme.Editor.FinderSync`,
    ///   * a team-prefixed group container — `ABCDE12345.com.acme.Editor`.
    /// Extensions an app's own files legitimately carry in these directories.
    /// Anything else after a dot is treated as another identifier component,
    /// not as a file type.
    private static let knownExtensions: Set<String> = [
        "plist", "savedState", "binarycookies", "bom", "sfl2", "sfl3", "lockfile",
    ]

    static func name(_ name: String, belongsTo identifier: String) -> Bool {
        // A short or dotless identifier is not specific enough to prefix-match
        // on. One real app on the test machine ships `st` as its bundle id;
        // prefix-matching that would claim `st.anything` across the system.
        // Those get exact matches only.
        let isSpecific = identifier.contains(".") && identifier.count >= 6

        if name == identifier { return true }

        // Strip only a *recognised* file extension. `deletingPathExtension`
        // removes any trailing dotted component, so on a dotless identifier
        // like `st` it would turn `st.anything` into a match — which is the
        // exact over-claim the specificity guard exists to prevent.
        let ext = (name as NSString).pathExtension
        if Self.knownExtensions.contains(ext), (name as NSString).deletingPathExtension == identifier {
            return true
        }
        guard isSpecific else { return false }

        if name.lowercased().hasPrefix(identifier.lowercased() + ".") { return true }

        // Group containers and their script directories carry one of two
        // prefixes ahead of the identifier: a literal `group.`, or the team
        // identifier. Both are anchored — the prefix must be exactly one of
        // those shapes, so this never accepts a string that merely happens to
        // end with the identifier.
        if let dot = name.firstIndex(of: ".") {
            let prefix = String(name[name.startIndex..<dot])
            let rest = String(name[name.index(after: dot)...])
            let isTeamIdentifier = prefix.count == 10 && prefix.allSatisfy { $0.isLetter || $0.isNumber }
            if isTeamIdentifier || prefix.lowercased() == "group" {
                // Compared case-insensitively: vendors are inconsistent about
                // it — `com.baidu.BaiduNetdisk-mac` ships alongside
                // `group.com.baidu.BaiduNetdisk-Mac`.
                let lowerRest = rest.lowercased(), lowerID = identifier.lowercased()
                return lowerRest == lowerID || lowerRest.hasPrefix(lowerID + ".")
            }
        }
        return false
    }

    private func makeItem(
        path: String,
        kind: Kind,
        ruleID: String,
        app: InstalledAppIndex.App
    ) -> ScanItem? {
        let url = URL(fileURLWithPath: path)
        let attributes = FileWalker.attributes(of: url)
        let measurement = attributes.isDirectory ? (try? FileWalker.measure(url)) : nil
        let bytes = measurement?.bytes ?? FileWalker.size(of: url)

        return ScanItem(
            path: path,
            displayName: url.lastPathComponent,
            category: .appUninstall,
            ruleID: ruleID,
            kindHint: kind.title,
            sizeBytes: bytes,
            fileCount: measurement?.fileCount ?? 1,
            isDirectory: attributes.isDirectory,
            lastModified: measurement?.newestModification ?? attributes.modified,
            lastAccessed: attributes.accessed,
            groupKey: app.bundleIdentifier,
            // The running-app check in RuleEngine keys off this. Deleting a
            // live app's container out from under it is the fastest way to
            // corrupt whatever it was writing.
            ownerHint: OwnerHint(bundleIdentifier: app.bundleIdentifier, appName: app.name),
            rebuildable: false
        )
    }
}
