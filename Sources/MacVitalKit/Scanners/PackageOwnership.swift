import Foundation

/// Which installer package, if any, put a path on disk.
///
/// The residue scanner decides that something is leftover by failing to
/// attribute it to an installed app. For `~/Library` that reasoning holds: an
/// app's own support directory has no other owner. Under `/Library` it does
/// not, because macOS itself installs there — and a directory belonging to the
/// operating system matches no installed app either.
///
/// `/Library/Application Support/BTServer` is the case that proved it: 46
/// Bluetooth country-code plists, `root:wheel`, written by a system update. The
/// scanner called it residue, the UI offered it for removal, and the advice
/// that followed was `sudo rm`. Nothing on the name-based deny list could have
/// caught it — `BTServer` carries no `com.apple.` prefix, and a hand-maintained
/// list of such names can never be complete.
///
/// `pkgutil` knows the answer authoritatively: it reads the installer receipt
/// database. Asking is a subprocess, so this is deliberately the *last* check —
/// only paths that have already survived attribution reach it, which on a real
/// machine is a few dozen at most.
public enum PackageOwnership {

    /// Package identifiers that claim this path, most specific first.
    public static func owningPackages(of path: String) -> [String] {
        if let cached = cache.value(for: path) { return cached }
        let result = query(path)
        cache.store(result, for: path)
        return result
    }

    /// True when macOS itself provides this path.
    ///
    /// Only Apple package identifiers suppress a finding. A third-party
    /// package owning a path proves nothing — a leftover launch daemon was
    /// installed by a package too, and that is exactly what makes it residue
    /// once the app is gone.
    public static func isSystemProvided(_ path: String) -> Bool {
        owningPackages(of: path).contains { $0.hasPrefix("com.apple.") }
    }

    // MARK: - Query

    private static func query(_ path: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        process.arguments = ["--file-info", path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            // No pkgutil, or it refused to start. Answering "unowned" keeps the
            // scanner behaving exactly as it did before this check existed.
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line in
                guard line.hasPrefix("pkgid: ") else { return nil }
                return String(line.dropFirst("pkgid: ".count)).trimmingCharacters(in: .whitespaces)
            }
    }

    // MARK: - Cache

    /// The rule engine evaluates every item twice — once at scan time, once
    /// before the move — so without this each answer costs two subprocesses.
    private static let cache = Cache()

    /// Drop everything remembered so far.
    ///
    /// The cache is process-wide and had no way out, so an answer from the
    /// first scan of a session was still being served hours later — after the
    /// user had installed or removed packages, which is exactly what
    /// `pkgutil` is being asked about. Cleared at the start of every scan: one
    /// scan is short enough that the answer cannot go stale inside it, which
    /// is the window the cache was added for.
    public static func invalidate() {
        cache.removeAll()
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: [String]] = [:]

        func value(for path: String) -> [String]? {
            lock.lock(); defer { lock.unlock() }
            return storage[path]
        }

        func store(_ value: [String], for path: String) {
            lock.lock(); storage[path] = value; lock.unlock()
        }

        func removeAll() {
            lock.lock(); storage.removeAll(); lock.unlock()
        }
    }
}
