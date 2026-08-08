import Foundation

/// The deny list. Two tiers, because they answer different questions.
///
/// `hardDeny` is absolute: nothing this app does can ever touch these paths.
/// Keychains, SSH keys, mail stores, Photos libraries, Time Machine, volume
/// roots. There is no rule, no confidence score and no user gesture that
/// unlocks them.
///
/// `sensitiveRoots` is conditional: Documents / Desktop / Downloads and friends
/// are denied *unless* the matching rule explicitly opts in via
/// `allowedInUserData`. Developers really do keep projects in ~/Documents, so a
/// blanket ban there would make the flagship feature useless — but only
/// rebuildable artifacts (node_modules, .build, target/, Pods) get the opt-in.
public struct ProtectedPaths: Sendable {
    public let home: String

    public init(home: String = PathRedaction.home) {
        self.home = home
    }

    // MARK: - Tier 1: absolute

    /// Directory prefixes that are never removable, at any depth.
    private var hardDenyPrefixes: [String] {
        [
            "/System",
            "/bin",
            "/sbin",
            "/usr/bin",
            "/usr/sbin",
            "/usr/lib",
            "/usr/libexec",
            "/usr/share",
            "/Library/Apple",
            "/private/var/db",
            "/private/var/folders/zz",
            "/private/etc",
            "/dev",
            "/Network",
            "/cores",
            "/.vol",
            "/Volumes/com.apple.TimeMachine",
            "/Applications/Safari.app",
            "/Applications/Utilities",
            "/System/Volumes",
        ] + [
            "\(home)/Library/Keychains",
            "\(home)/Library/Mail",
            "\(home)/Library/Messages",
            "\(home)/Library/Calendars",
            "\(home)/Library/AddressBook",
            "\(home)/Library/Photos",
            "\(home)/Library/CloudStorage",
            "\(home)/Library/Mobile Documents",
            "\(home)/Library/Application Support/AddressBook",
            "\(home)/Library/Application Support/com.apple.TCC",
            "\(home)/Library/Application Support/MobileSync",
            "\(home)/.ssh",
            "\(home)/.gnupg",
            "\(home)/.aws",
            "\(home)/.kube",
            "\(home)/.config/gh",
        ]
    }

    /// Exact paths that must never be the target of a removal, even though
    /// things *inside* them may be.
    private var criticalExactPaths: Set<String> {
        [
            "/", "/Users", "/Volumes", "/Applications", "/Library", "/private", "/opt", "/usr", "/tmp", "/var",
            home,
            "\(home)/Library",
            "\(home)/Library/Caches",
            "\(home)/Library/Preferences",
            "\(home)/Library/Application Support",
            "\(home)/Library/Containers",
            "\(home)/Library/Group Containers",
            "\(home)/Library/Developer",
            "\(home)/Library/Developer/Xcode",
            "\(home)/Documents", "\(home)/Desktop", "\(home)/Downloads",
            "\(home)/Pictures", "\(home)/Movies", "\(home)/Music", "\(home)/Public",
        ]
    }

    /// Filename suffixes that indicate irreplaceable user libraries.
    private let protectedBundleSuffixes: [String] = [
        ".photoslibrary", ".photolibrary", ".aplibrary",
        ".sparsebundle", ".backupbundle", ".dmg.sparseimage",
        ".fcpbundle", ".imovielibrary", ".logicx", ".band",
        ".keychain", ".keychain-db",
        ".pem", ".p12", ".mobileprovision",
    ]

    // MARK: - Tier 2: conditional

    /// User data roots. Denied by default; a rule may opt in.
    private var sensitiveRoots: [String] {
        [
            "\(home)/Documents",
            "\(home)/Desktop",
            "\(home)/Downloads",
            "\(home)/Pictures",
            "\(home)/Movies",
            "\(home)/Music",
            "\(home)/Public",
            "\(home)/Library/Mobile Documents",
        ]
    }

    // MARK: - Queries

    public func isHardDenied(_ path: String) -> DenyReason? {
        let normalized = Self.normalize(path)

        if criticalExactPaths.contains(normalized) {
            return .criticalPath
        }
        // Never the root of a mounted volume.
        if normalized.hasPrefix("/Volumes/"), normalized.split(separator: "/").count == 2 {
            return .criticalPath
        }
        // Refuse anything shallower than three components under `/`, e.g. /Library/Foo.
        // Real cleanup targets live deeper than that.
        //
        // One documented exception: `/Applications/Foo.app` is two components
        // by construction, and it is the single shape a two-component path is
        // ever allowed to have. The carve-out is deliberately narrow — the
        // parent must be exactly `/Applications` and the name must end in
        // `.app` — and it grants nothing on its own: `/Applications/Safari.app`
        // and `/Applications/Utilities` are still caught by the prefix list
        // below, and any bundle under `/System` never reaches here at all.
        if normalized.split(separator: "/").count < 3, !Self.isApplicationBundle(normalized) {
            return .pathTooShallow
        }
        for prefix in hardDenyPrefixes where isUnder(normalized, prefix) {
            // Second documented exception, and the only hole in an otherwise
            // absolute list. `/private/var/db` is denied because it holds the
            // local account database, the TCC stores and configuration
            // profiles — losing any of those is unrecoverable. Installer
            // receipts sit in one subdirectory of it and are merely a record
            // that a package was installed; removing them makes `pkgutil`
            // forget the package and nothing else.
            //
            // The exemption is a single named subdirectory, one level deep,
            // and it does not exempt the directory itself. Everything else
            // under /private/var/db stays denied.
            if Self.isInstallerReceipt(normalized) { break }
            return .criticalPath
        }
        let name = (normalized as NSString).lastPathComponent.lowercased()
        for suffix in protectedBundleSuffixes where name.hasSuffix(suffix) {
            return .protectedUserData
        }
        // /usr/local and /opt/homebrew are the two writable exceptions inside
        // otherwise-protected prefixes; they are handled by not listing them.
        return nil
    }

    public func isInSensitiveUserData(_ path: String) -> Bool {
        let normalized = Self.normalize(path)
        return sensitiveRoots.contains { isUnder(normalized, $0) }
    }

    // MARK: - Helpers

    /// True when `path` is `prefix` itself or lives beneath it. Compares whole
    /// components so `/Systemic` is not "under" `/System`.
    func isUnder(_ path: String, _ prefix: String) -> Bool {
        if path == prefix { return true }
        return path.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
    }

    /// `/Applications/Foo.app` and nothing else. Not `~/Applications/Foo.app`
    /// (already four components deep), not a nested bundle, not a directory
    /// that merely lives beside one.
    static func isApplicationBundle(_ normalized: String) -> Bool {
        (normalized as NSString).deletingLastPathComponent == "/Applications"
            && normalized.hasSuffix(".app")
    }

    /// A file sitting directly in `/private/var/db/receipts`, and nothing else.
    /// Not the directory itself, not anything nested below it, not a sibling
    /// directory under `/private/var/db`.
    static func isInstallerReceipt(_ normalized: String) -> Bool {
        (normalized as NSString).deletingLastPathComponent == "/private/var/db/receipts"
            && !normalized.hasSuffix("/receipts")
    }

    public static func normalize(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        // standardizingPath maps /private/var -> /var on some inputs; keep the
        // firmlink-resolved form so prefix checks are consistent.
        if p.hasPrefix("/var/") { p = "/private" + p }
        if p.hasPrefix("/etc/") { p = "/private" + p }
        if p.hasPrefix("/tmp/") { p = "/private" + p }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
