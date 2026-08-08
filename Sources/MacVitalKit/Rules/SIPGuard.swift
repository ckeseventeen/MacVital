import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Asks the filesystem, not a hardcoded list, whether a path is protected.
///
/// The static prefix list in `ProtectedPaths` is the first line of defence, but
/// SIP coverage changes between OS releases and third-party installers set
/// immutable flags of their own. `st_flags` is the ground truth.
public enum SIPGuard {
    // <sys/stat.h>. Redeclared because the Darwin overlay does not export the
    // full set of BSD file flags to Swift.
    private static let UF_IMMUTABLE: UInt32 = 0x0000_0002
    private static let SF_IMMUTABLE: UInt32 = 0x0002_0000
    private static let SF_RESTRICTED: UInt32 = 0x0008_0000 // the SIP bit
    private static let UF_DATAVAULT: UInt32 = 0x0000_0080

    public enum Flag: Sendable {
        case restricted
        case immutable
        case dataVault
    }

    /// Returns the blocking flag, if any. `nil` means the flags are clear —
    /// which is not by itself permission to delete.
    public static func blockingFlag(at path: String) -> Flag? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let flags = UInt32(info.st_flags)

        if flags & SF_RESTRICTED != 0 { return .restricted }
        if flags & UF_DATAVAULT != 0 { return .dataVault }
        if flags & (UF_IMMUTABLE | SF_IMMUTABLE) != 0 { return .immutable }
        return nil
    }

    public static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// Resolves symlinks the whole way down. A rule that matches
    /// `~/Library/Caches/foo` must not become a delete of `~/Documents` because
    /// `foo` is a symlink.
    public static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// True when the entry itself is a symlink (as opposed to pointing at one).
    public static func isSymlink(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFLNK
    }

    /// Whether the current process can unlink the entry from its parent —
    /// which needs write permission on the *parent*, not the entry.
    public static func currentUserCanRemove(_ path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        return access(parent, W_OK) == 0 && access(path, W_OK) == 0
    }
}
