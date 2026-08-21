import Foundation

/// Who a launchd job belongs to, read from the job itself.
///
/// The residue scanner attributes by *filename*, which for launchd plists is
/// close to useless: `com.docker.vmnetd.plist` matches no installed app,
/// because Docker Desktop's bundle identifier is `com.docker.docker`. Nor does
/// `io.github.clash-verge-rev.clash-verge-rev.service.plist`, or
/// `com.netease.uuremote.daemon.plist` — while UURemote.app sits in
/// `/Applications` and its daemon is loaded and running.
///
/// All three were reported as the leftovers of uninstalled apps. Acting on that
/// would have broken Docker, a VPN and an accelerator that were all working.
///
/// The plist says who it belongs to. `Program` (or `ProgramArguments[0]`) is a
/// path, and a path that still exists is the strongest possible evidence that
/// the job is not orphaned — whatever its filename suggests.
public enum LaunchItemAttribution {

    /// The executable a launchd plist points at.
    public static func program(atPlist path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]),
              data.count < 4_000_000,
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let plist = object as? [String: Any]
        else { return nil }

        if let program = plist["Program"] as? String { return program }
        // `ProgramArguments` is argv, so argv[0] is the executable.
        return (plist["ProgramArguments"] as? [String])?.first
    }

    /// What a job's target says about whether the job is still wanted.
    public enum Liveness: Equatable, Sendable {
        /// The program lives inside an `.app` that is still installed. This is
        /// the one conclusive "leave it alone" answer.
        case liveInsideApp(bundlePath: String)
        /// The program lives inside an `.app` that is gone. Conclusively
        /// residue.
        case orphanedApp(bundlePath: String)
        /// A bare executable — typically `/Library/PrivilegedHelperTools/…`.
        ///
        /// Its existence proves nothing. Uninstalling an app leaves its
        /// privileged helper behind, so the daemon goes on pointing at a real
        /// file forever. Docker, Clash Verge and Bitboo were all uninstalled on
        /// the machine this was found on, and all three helpers were still
        /// sitting there. Callers must fall through to attribution rather than
        /// treat this as evidence of life.
        case bareHelper(program: String)
        /// The program is gone. Conclusively residue — every login wastes a
        /// launch attempt on it.
        case targetMissing
    }

    public static func liveness(ofPlist path: String) -> Liveness {
        guard let program = program(atPlist: path) else { return .targetMissing }
        return liveness(program: program)
    }

    /// True only when the job belongs to an app that is still installed.
    ///
    /// Deliberately narrower than "the target file exists", which was the first
    /// version and was wrong in the expensive direction: it hid three genuinely
    /// orphaned daemons because the helpers they point at outlive their apps.
    public static func belongsToAnInstalledApp(plist path: String) -> Bool {
        if case .liveInsideApp = liveness(ofPlist: path) { return true }
        return false
    }

    /// The `.app` bundle an executable lives inside, if it lives inside one.
    ///
    /// `/Applications/UURemote.app/Contents/MacOS/UURemoteDaemon` is four
    /// levels down; a bare helper in `/Library/PrivilegedHelperTools` is inside
    /// nothing. Bounded rather than general — a runaway walk on a malformed
    /// path is not worth the generality, and no bundle nests deeper than this.
    public static func enclosingAppBundle(of executable: String) -> String? {
        var url = URL(fileURLWithPath: executable)
        for _ in 0..<6 {
            url = url.deletingLastPathComponent()
            guard url.path != "/" else { return nil }
            if url.pathExtension == "app" {
                return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
            }
        }
        return nil
    }

    /// Directories holding launchd jobs that could reference a helper binary.
    private static var launchItemDirectories: [String] {
        [
            "/Library/LaunchDaemons",
            "/Library/LaunchAgents",
            "\(PathRedaction.home)/Library/LaunchAgents",
        ]
    }

    /// True when some launchd job still points at this path.
    ///
    /// A privileged helper is named after the vendor, not after any installed
    /// bundle identifier, so filename attribution never places it. What does
    /// place it is the daemon that launches it — and if that daemon is on disk,
    /// removing the helper breaks it.
    /// Only references from a job that itself belongs to an installed app
    /// count. A daemon left behind by an uninstall still points at its helper,
    /// so counting that reference would keep both of them alive forever — each
    /// one vouching for the other.
    public static func isReferencedByALiveLaunchItem(_ path: String) -> Bool {
        liveTargetPrefixes.value().contains(ProtectedPaths.normalize(path))
    }

    /// Forget the cached launch-item index. Called at the start of a scan.
    public static func invalidate() {
        liveTargetPrefixes.reset()
    }

    /// Every program a live launch item points at, plus each of their ancestor
    /// directories — so "is the target at or under this path" is one lookup.
    ///
    /// This used to re-read all three launchd directories and re-parse every
    /// plist in them (twice per plist: once to attribute it, once to read its
    /// program) for *each* residue candidate. On a machine with a few dozen
    /// candidates and a hundred launch items that is thousands of property-list
    /// parses to answer a question whose inputs did not change. Same shape as
    /// `RunningProcessIndex.occupiedPrefixes`, for the same reason.
    private static let liveTargetPrefixes = MemoizedStringSet {
        var prefixes = Set<String>()
        for directory in launchItemDirectories {
            for child in FileWalker.children(of: URL(fileURLWithPath: directory))
            where child.pathExtension == "plist" {
                guard let program = program(atPlist: child.path) else { continue }
                guard case .liveInsideApp = liveness(program: program) else { continue }

                var path = ProtectedPaths.normalize(program)
                while path.count > 1 {
                    prefixes.insert(path)
                    let parent = (path as NSString).deletingLastPathComponent
                    if parent == path || parent.isEmpty { break }
                    path = parent
                }
            }
        }
        return prefixes
    }

    /// `liveness(ofPlist:)` without re-reading the plist.
    private static func liveness(program: String) -> Liveness {
        guard FileManager.default.fileExists(atPath: program) else { return .targetMissing }
        guard let bundle = enclosingAppBundle(of: program) else {
            return .bareHelper(program: program)
        }
        return FileManager.default.fileExists(atPath: bundle)
            ? .liveInsideApp(bundlePath: bundle)
            : .orphanedApp(bundlePath: bundle)
    }
}
