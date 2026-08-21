import Foundation

/// Reverse-DNS namespaces that belong to the operating system rather than to
/// any app the user installed.
///
/// `com.apple.` is the obvious one and a prefix list covers it. The ones that
/// bit are the others: macOS ships CUPS, Apache, OpenLDAP, net-snmp, cron and
/// friends under *their upstream* namespaces, and those carry no Apple prefix
/// at all.
///
/// `/Library/Preferences/org.cups.printers.plist` is the case that proved it.
/// It holds every printer the user has configured. It matches no installed app,
/// because CUPS is not an app; it carries no `com.apple.` prefix; and
/// `pkgutil --file-info` reports no package, because `cupsd` *writes* the file
/// at runtime rather than an installer placing it. Every existing guard let it
/// through, and the residue scanner offered the user's printer configuration
/// for removal under a privileged rule.
///
/// A hand-maintained list of such names can never be complete — the same
/// argument that produced `PackageOwnership`. So this asks the system instead:
/// the jobs in `/System/Library/LaunchDaemons` and `/System/Library/LaunchAgents`
/// are, by definition, the ones macOS ships, and their labels name every
/// subsystem namespace the OS occupies. `org.cups.cupsd` is right there, next
/// to `org.apache.httpd`, `com.vix.cron` and `org.openldap.slapd`.
public enum SystemDomainIndex {

    /// True when `identifier` sits inside a namespace the OS occupies.
    ///
    /// Compared on the first two components — `org.cups` claims
    /// `org.cups.printers` and `org.cups.cups-lpd`, and nothing else.
    public static func isSystemDomain(_ identifier: String) -> Bool {
        guard let prefix = vendorPrefix(of: identifier) else { return false }
        return prefixes.value().contains(prefix)
    }

    /// Forget the cached index. Called at the start of a scan.
    public static func invalidate() {
        prefixes.reset()
    }

    /// `com.acme.App.helper` -> `com.acme`. Nil when the name is not shaped
    /// like a reverse-DNS identifier at all.
    static func vendorPrefix(of identifier: String) -> String? {
        let parts = identifier.lowercased().split(separator: ".")
        guard parts.count >= 2 else { return nil }
        return parts.prefix(2).joined(separator: ".")
    }

    /// Where the OS keeps the jobs it ships. Deliberately not `/Library`:
    /// that is where third parties install, which is the whole distinction
    /// being drawn here.
    private static let systemLaunchDirectories = [
        "/System/Library/LaunchDaemons",
        "/System/Library/LaunchAgents",
    ]

    /// Always denied, whether or not a matching job is on this machine.
    ///
    /// A namespace does not stop being Apple's because the daemon that uses it
    /// happens to be absent — a Mac with no printers configured still must not
    /// have `org.cups.*` proposed for removal.
    private static let known: Set<String> = [
        "com.apple", "org.cups", "org.apache", "org.openldap", "org.net-snmp",
        "com.vix", "com.openssh", "org.openbsd", "org.postfix", "org.ntp",
        "org.freedesktop", "com.microsoft.autoupdate.helper",
    ]

    private static let prefixes = MemoizedStringSet {
        var found = known
        for directory in systemLaunchDirectories {
            for child in FileWalker.children(of: URL(fileURLWithPath: directory))
            where child.pathExtension == "plist" {
                // The filename is the label by convention, and reading it does
                // not require parsing the plist. `LaunchItemAttribution` parses
                // when it needs the program; here the name is the whole answer.
                let label = child.deletingPathExtension().lastPathComponent
                if let prefix = vendorPrefix(of: label) { found.insert(prefix) }
            }
        }
        return found
    }
}

/// A set built on first use and thrown away on demand.
final class MemoizedStringSet: @unchecked Sendable {
    private let lock = NSLock()
    private let build: () -> Set<String>
    private var cached: Set<String>?

    init(_ build: @escaping () -> Set<String>) {
        self.build = build
    }

    func value() -> Set<String> {
        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Built outside the lock: it reads the filesystem, and holding a lock
        // across that would serialise the scanners running concurrently. Two
        // threads racing here both do the work and agree on the result.
        let fresh = build()

        lock.lock()
        cached = fresh
        lock.unlock()
        return fresh
    }

    func reset() {
        lock.lock()
        cached = nil
        lock.unlock()
    }
}
