import Foundation

/// Something that runs on its own, without the user launching it.
public struct LoginItem: Identifiable, Sendable {
    public enum Scope: String, Sendable {
        /// `~/Library/LaunchAgents` — runs when this user logs in.
        case userAgent
        /// `/Library/LaunchAgents` — runs when any user logs in. Root-owned.
        case systemAgent
        /// `/Library/LaunchDaemons` — runs at boot, as root, before login.
        case daemon

        public var title: String {
            switch self {
            case .userAgent: return "登录时运行"
            case .systemAgent: return "所有用户登录时运行"
            case .daemon: return "开机时以 root 运行"
            }
        }

        public var directory: String {
            switch self {
            case .userAgent: return "\(PathRedaction.home)/Library/LaunchAgents"
            case .systemAgent: return "/Library/LaunchAgents"
            case .daemon: return "/Library/LaunchDaemons"
            }
        }

        /// The catalog rule that governs removing this kind of item. The
        /// startup manager adds no rules of its own — disabling an item is the
        /// same quarantine move the cleaner already performs, so it inherits
        /// the same guards and the same one-click restore.
        public var ruleID: String {
            switch self {
            case .userAgent: return "residue.launchAgents"
            case .systemAgent: return "residue.systemLaunchAgents"
            case .daemon: return "residue.systemLaunchDaemons"
            }
        }

        public var requiresPrivilege: Bool { self != .userAgent }
    }

    public var id: String { path }
    /// Absolute path of the plist that defines the job.
    public var path: String
    public var scope: Scope
    /// `Label` from the plist — launchd's identifier for the job.
    public var label: String
    /// What it actually launches, as written in the plist.
    public var program: String?
    /// Whether the program still exists on disk. `false` means every login
    /// wastes a launch attempt on something that is gone.
    public var programExists: Bool
    public var runAtLoad: Bool
    public var keepAlive: Bool
    /// Best guess at who installed it.
    public var ownerName: String?
    /// What to ask the workspace for an icon. The owning `.app` bundle when we
    /// can find one, otherwise the executable itself — which still yields the
    /// generic tool icon rather than nothing.
    public var iconPath: String?
    public var sizeBytes: Int64
    public var modified: Date?

    /// An item whose target is missing is dead weight by definition — nothing
    /// subjective about it, and the safest thing in the list to remove.
    public var isOrphaned: Bool { program != nil && !programExists }

    public var displayName: String {
        ownerName ?? label
    }
}

/// Reads the three launchd directories a user can actually manage.
///
/// Deliberately does not touch `launchctl`: unloading a job mutates live system
/// state in a way that is awkward to undo and invisible in the UI. Moving the
/// plist to quarantine achieves the same thing for the *next* login, is fully
/// reversible, and is a path the rule engine already understands.
public struct LoginItemScanner: Sendable {

    /// Apple's own jobs. Removing these breaks the OS and none of them are
    /// what a user means by "startup item".
    private static let systemLabelPrefixes = ["com.apple.", "com.openssh.", "org.openbsd."]

    public init() {}

    public func scan(installedApps: InstalledAppIndex? = nil) -> [LoginItem] {
        let index = installedApps ?? InstalledAppIndex.build()
        var items: [LoginItem] = []

        for scope in [LoginItem.Scope.userAgent, .systemAgent, .daemon] {
            let root = URL(fileURLWithPath: scope.directory)
            guard FileWalker.exists(root) else { continue }

            for child in FileWalker.children(of: root) where child.pathExtension == "plist" {
                guard let item = makeItem(url: child, scope: scope, index: index) else { continue }
                items.append(item)
            }
        }

        return items.sorted { lhs, rhs in
            // Broken jobs first — they are the ones with an unambiguous answer.
            if lhs.isOrphaned != rhs.isOrphaned { return lhs.isOrphaned }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func makeItem(url: URL, scope: LoginItem.Scope, index: InstalledAppIndex) -> LoginItem? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let plist = object as? [String: Any]
        else { return nil }

        let label = (plist["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
        guard !Self.systemLabelPrefixes.contains(where: { label.lowercased().hasPrefix($0) }) else { return nil }

        // `Program` is a bare path; `ProgramArguments` is argv, so argv[0] is
        // the executable. Jobs use one or the other, never both meaningfully.
        let program = (plist["Program"] as? String)
            ?? (plist["ProgramArguments"] as? [String])?.first

        let attributes = FileWalker.attributes(of: url)
        let owner = index.match(residueName: label)

        return LoginItem(
            path: ProtectedPaths.normalize(url.path),
            scope: scope,
            label: label,
            program: program,
            programExists: program.map { FileManager.default.fileExists(atPath: $0) } ?? false,
            runAtLoad: (plist["RunAtLoad"] as? Bool) ?? false,
            keepAlive: Self.readKeepAlive(plist["KeepAlive"]),
            ownerName: Self.ownerName(for: owner),
            iconPath: Self.iconPath(program: program, match: owner),
            sizeBytes: FileWalker.size(of: url),
            modified: attributes.modified
        )
    }

    /// A login item points at an executable, not an app. `/Applications/Foo.app/
    /// Contents/MacOS/Foo` has the icon four levels up; a bare helper in
    /// `/Library/PrivilegedHelperTools` has none of its own, so fall back to the
    /// installed app we attributed it to.
    private static func iconPath(program: String?, match: InstalledAppIndex.Match) -> String? {
        if let program, let bundle = enclosingAppBundle(of: program) { return bundle }

        switch match {
        case .installed(let app), .nameSimilar(let app):
            return app.path
        case .vendorInstalled, .none:
            break
        }

        // Last resort: the executable itself. Better a generic tool icon than
        // an empty column.
        if let program, FileManager.default.fileExists(atPath: program) { return program }
        return nil
    }

    private static func enclosingAppBundle(of executable: String) -> String? {
        var url = URL(fileURLWithPath: executable)
        // Bounded walk — a runaway loop on a malformed path is not worth the
        // generality, and no bundle nests deeper than this.
        for _ in 0..<6 {
            url = url.deletingLastPathComponent()
            guard url.path != "/" else { return nil }
            if url.pathExtension == "app" {
                return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
            }
        }
        return nil
    }

    /// `KeepAlive` is either a Bool or a dictionary of conditions; a dictionary
    /// means "keep alive under these circumstances", which is still keep-alive.
    private static func readKeepAlive(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if value is [String: Any] { return true }
        return false
    }

    private static func ownerName(for match: InstalledAppIndex.Match) -> String? {
        switch match {
        case .installed(let app), .nameSimilar(let app):
            return app.name
        case .vendorInstalled(let vendor):
            return vendor
        case .none:
            return nil
        }
    }

    /// Turn an item into something the cleanup pipeline accepts. The rule ID
    /// comes from the scope, so `RuleEngine` re-derives permission from the
    /// same catalog every other removal uses.
    public static func scanItem(for item: LoginItem) -> ScanItem {
        ScanItem(
            path: item.path,
            displayName: item.displayName,
            category: .appUninstall,
            ruleID: item.scope.ruleID,
            kindHint: item.scope.title,
            sizeBytes: max(item.sizeBytes, 1),
            fileCount: 1,
            isDirectory: false,
            lastModified: item.modified,
            groupKey: item.label,
            rebuildable: false
        )
    }
}
