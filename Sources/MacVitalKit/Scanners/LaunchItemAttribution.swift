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

    /// True when the job still points at something that exists.
    ///
    /// This is the check that keeps a working daemon out of the residue list.
    public static func targetExists(forPlist path: String) -> Bool {
        guard let program = program(atPlist: path) else { return false }
        return FileManager.default.fileExists(atPath: program)
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
    public static func isReferencedByALaunchItem(_ path: String) -> Bool {
        let normalized = ProtectedPaths.normalize(path)
        for directory in launchItemDirectories {
            for child in FileWalker.children(of: URL(fileURLWithPath: directory))
            where child.pathExtension == "plist" {
                guard let program = program(atPlist: child.path) else { continue }
                let target = ProtectedPaths.normalize(program)
                if target == normalized || target.hasPrefix(normalized + "/") { return true }
            }
        }
        return false
    }
}
