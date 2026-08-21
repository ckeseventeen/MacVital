import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Snapshot of what is currently running, used to refuse deletions that would
/// pull the rug out from under a live process.
///
/// Deliberately cheap: `proc_listallpids` + `proc_pidpath` for executables, and
/// NSWorkspace for bundle identifiers. A full `lsof` sweep over every candidate
/// path would take minutes on a real Mac; this catches the cases that actually
/// cause data loss (deleting a running app's container, wiping a build
/// directory a compiler is writing into).
public struct RunningProcessIndex: Sendable {
    public struct Entry: Hashable, Sendable {
        public let pid: pid_t
        public let executablePath: String
        public let bundleIdentifier: String?
        public let localizedName: String?
    }

    public let entries: [Entry]
    private let runningBundleIDs: Set<String>
    /// Every ancestor directory of every running executable, plus the
    /// executables themselves.
    ///
    /// `executingProcess(under:)` used to scan the whole entry list per query,
    /// prefix-comparing strings. With ~600 processes on an ordinary Mac and a
    /// few thousand candidates — each evaluated twice — that is millions of
    /// comparisons. A candidate path can only contain a running executable if
    /// it appears in this set, so the common case (no match) becomes one hash
    /// lookup and the linear scan runs only for the handful that do match.
    private let occupiedPrefixes: Set<String>

    public init(entries: [Entry]) {
        // Executable paths are compared against realpath-resolved candidates,
        // so they have to go through the same normalisation. NSWorkspace and
        // proc_pidpath do not agree on /var vs /private/var.
        let normalized = entries.map { entry in
            Entry(
                pid: entry.pid,
                executablePath: ProtectedPaths.normalize(entry.executablePath),
                bundleIdentifier: entry.bundleIdentifier,
                localizedName: entry.localizedName
            )
        }
        self.entries = normalized
        self.runningBundleIDs = Set(normalized.compactMap { $0.bundleIdentifier?.lowercased() })

        var prefixes = Set<String>()
        for entry in normalized where !entry.executablePath.isEmpty {
            var path = entry.executablePath
            while path.count > 1 {
                prefixes.insert(path)
                let parent = (path as NSString).deletingLastPathComponent
                if parent == path || parent.isEmpty { break }
                path = parent
            }
        }
        self.occupiedPrefixes = prefixes
    }

    public static func snapshot() -> RunningProcessIndex {
        var byPID: [pid_t: Entry] = [:]

        #if canImport(AppKit)
        for app in NSWorkspace.shared.runningApplications {
            let path = app.executableURL?.path ?? app.bundleURL?.path ?? ""
            byPID[app.processIdentifier] = Entry(
                pid: app.processIdentifier,
                executablePath: path,
                bundleIdentifier: app.bundleIdentifier,
                localizedName: app.localizedName
            )
        }
        #endif

        for pid in allPIDs() where byPID[pid] == nil {
            guard let path = executablePath(for: pid) else { continue }
            byPID[pid] = Entry(pid: pid, executablePath: path, bundleIdentifier: nil, localizedName: nil)
        }

        return RunningProcessIndex(entries: Array(byPID.values))
    }

    // MARK: - Queries

    /// A process whose executable lives under `path` — deleting it would kill
    /// a running program.
    public func executingProcess(under path: String) -> Entry? {
        guard occupiedPrefixes.contains(path) else { return nil }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return entries.first { $0.executablePath == path || $0.executablePath.hasPrefix(prefix) }
    }

    public func isRunning(bundleIdentifier: String) -> Bool {
        runningBundleIDs.contains(bundleIdentifier.lowercased())
    }

    /// Best-effort name for the process that would be affected.
    public func describe(_ entry: Entry) -> String {
        entry.localizedName
            ?? entry.bundleIdentifier
            ?? (entry.executablePath as NSString).lastPathComponent
    }

    // MARK: - libproc

    private static func allPIDs() -> [pid_t] {
        let byteCount = proc_listallpids(nil, 0)
        guard byteCount > 0 else { return [] }
        let capacity = Int(byteCount) / MemoryLayout<pid_t>.size + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = pids.withUnsafeMutableBufferPointer { buffer -> Int32 in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard written > 0 else { return [] }
        let count = Int(written) / MemoryLayout<pid_t>.size
        return Array(pids.prefix(count)).filter { $0 > 0 }
    }

    /// Whether `pid` is still running the executable it was recorded with.
    ///
    /// A PID is not a stable handle. A verdict naming one is produced during a
    /// scan and may be acted on minutes later, and macOS hands PIDs out again
    /// once they are freed — so by then the number can belong to something
    /// else entirely. Anything about to *signal* a recorded PID has to ask this
    /// first; the difference between "the compiler you wanted to stop" and
    /// "whatever happened to start next" is invisible from the number alone.
    ///
    /// Lives here rather than beside the code that sends the signal so it can
    /// be tested: the app target deliberately has no test bundle, because
    /// building one produces a second, unsigned `MacVital.app` and macOS may
    /// resolve the bundle identifier to *that* when checking a TCC requirement.
    public static func isRunning(pid: pid_t, executablePath: String) -> Bool {
        guard let current = currentExecutablePath(for: pid) else { return false }
        return current == ProtectedPaths.normalize(executablePath)
    }

    /// The executable a live PID is running, normalised the same way entries
    /// are. `nil` when the process is gone or belongs to someone else.
    ///
    /// Public because the terminator needs it to confirm a recorded PID still
    /// means what it meant at scan time, and reimplementing `proc_pidpath` on
    /// the other side of the module boundary would be two copies of one answer.
    public static func currentExecutablePath(for pid: pid_t) -> String? {
        executablePath(for: pid).map(ProtectedPaths.normalize)
    }

    private static func executablePath(for pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE == 4 * MAXPATHLEN.
        let capacity = 4 * 1024
        var buffer = [CChar](repeating: 0, count: capacity)
        let length = proc_pidpath(pid, &buffer, UInt32(capacity))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
