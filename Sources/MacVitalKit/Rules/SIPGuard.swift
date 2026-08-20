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

    /// True when an ACL on the entry, or anywhere beneath it, denies deletion.
    ///
    /// macOS puts `group:everyone deny delete` on several directories under
    /// `~/Library` — `Spelling`, `FontCollections`, `Favorites` and friends —
    /// so a stray `rm -rf` cannot take them. Nothing above notices: `st_flags`
    /// is clear, the owner is the user, the mode is 700, and `access(W_OK)`
    /// does not evaluate the ACL's delete permission at all.
    ///
    /// So they passed every check, were moved into quarantine, and then could
    /// not be deleted *or* restored — restoring has to move them out again.
    /// Two of them wedged the store permanently, and the failure surfaced as a
    /// code-signing complaint about the privileged helper, which is three
    /// layers away from the truth.
    ///
    /// Checked recursively but bounded: the ACL is usually on the directory
    /// itself, and walking an enormous tree to find one is not worth the cost
    /// of the check running on every candidate.
    public static func hasDeleteDenyACL(at path: String, maxEntries: Int = 512) -> Bool {
        if entryDeniesDelete(path) { return true }

        var visited = 0
        guard let enumerator = FileManager.default.enumerator(
            atPath: path
        ) else { return false }

        for case let relative as String in enumerator {
            visited += 1
            if visited > maxEntries { break }
            if entryDeniesDelete((path as NSString).appendingPathComponent(relative)) { return true }
        }
        return false
    }

    private static func entryDeniesDelete(_ path: String) -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }

        var entry: acl_entry_t?
        var index = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, Int32(index), &entry) == 0 {
            index = ACL_NEXT_ENTRY.rawValue
            guard let entry else { continue }

            var tag = ACL_EXTENDED_ALLOW
            guard acl_get_tag_type(entry, &tag) == 0, tag == ACL_EXTENDED_DENY else { continue }
            guard let permset = try? permissionSet(of: entry) else { continue }
            if acl_get_perm_np(permset, ACL_DELETE) == 1 { return true }
            if acl_get_perm_np(permset, ACL_DELETE_CHILD) == 1 { return true }
        }
        return false
    }

    private static func permissionSet(of entry: acl_entry_t) throws -> acl_permset_t {
        var permset: acl_permset_t?
        guard acl_get_permset(entry, &permset) == 0, let permset else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return permset
    }
}
