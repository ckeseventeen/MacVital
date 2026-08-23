import Foundation

/// Everything memoised about the machine's current state, dropped together.
///
/// Four separate caches exist because four separate questions are expensive to
/// ask: which package owns a path, which launchd jobs are live, which
/// reverse-DNS namespaces the OS occupies, and where LaunchServices thinks a
/// bundle identifier lives. Each is cheap to answer once and wasteful to answer
/// per candidate, so each remembers.
///
/// They were reset in `ScanEngine.scan` and nowhere else — which was fine for
/// the junk cleaner and wrong for the other two screens, because neither goes
/// through `ScanEngine`. The uninstall page builds its own engine, and the
/// startup page builds one on every reload. Both were served whatever the last
/// sweep had memoised, for the life of the process.
///
/// The visible version of that: disable a launch item, watch the list reload,
/// and the row still says the job will be restarted by launchd — because the
/// index that answers the question was built before the plist was quarantined.
/// The action worked and the interface said it had not.
///
/// So the reset lives here, named once, and every entry point calls it.
public enum ScanCaches {

    /// Forget everything. Call at the start of any pass that reads the state
    /// of the machine — a scan, an uninstall plan, a startup-item reload.
    public static func invalidate() {
        PackageOwnership.invalidate()
        LaunchItemAttribution.invalidate()
        SystemDomainIndex.invalidate()
        InstalledAppIndex.invalidateLaunchServicesCache()
    }
}
