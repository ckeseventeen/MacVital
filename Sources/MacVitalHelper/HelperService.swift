import Foundation
import MacVitalKit

/// Runs as root. Assumes the client is hostile.
///
/// The app already ran every path through `RuleEngine` before asking. That is
/// not a reason for this side to skip the checks — it is a reason for the two
/// sides to share the same catalog and run it twice. A bug in the app, a
/// spoofed client, or a malicious caller that got past the code-signing
/// requirement all hit the same wall here.
final class HelperService: NSObject, MacVitalHelperProtocol {

    /// Running as root, `NSHomeDirectory()` is /var/root, so the home-relative
    /// entries in the deny list would be meaningless here. Point them at an
    /// empty directory: the system-prefix half of the list still applies, and
    /// the privileged-rule match below is what actually gates this side.
    private let protectedPaths = ProtectedPaths(home: "/var/empty")
    /// Same catalog the app uses. Only the `requiresPrivilege` rules have
    /// absolute patterns, and only those can match anything from here.
    private let rules = RuleIndex()

    // MARK: - Version

    func helperVersion(withReply reply: @escaping (String) -> Void) {
        reply(HelperConstants.version)
    }

    // MARK: - Move to quarantine

    func moveToQuarantine(
        paths: [String],
        quarantineRoot: String,
        withReply reply: @escaping ([String: String], [String: String]) -> Void
    ) {
        var moved: [String: String] = [:]
        var failures: [String: String] = [:]

        guard let root = validatedQuarantineRoot(quarantineRoot) else {
            for path in paths { failures[path] = "隔离区路径不合法" }
            reply(moved, failures)
            return
        }

        for path in paths {
            do {
                let source = try validatedRemovalSource(path)
                let container = root
                    .appendingPathComponent("Items", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
                let destination = container.appendingPathComponent(source.lastPathComponent)

                try FileManager.default.moveItem(at: source, to: destination)
                // The store is owned by the user, not root. Hand ownership of
                // what we just moved back so the app can restore or purge it
                // without needing us again.
                chownToOwner(of: root, path: container)
                moved[path] = destination.path
                NSLog("[MacVitalHelper] quarantined %@", source.lastPathComponent)
            } catch {
                failures[path] = error.localizedDescription
            }
        }
        reply(moved, failures)
    }

    // MARK: - Restore

    func restore(
        storedPath: String,
        originalPath: String,
        quarantineRoot: String,
        withReply reply: @escaping (String?) -> Void
    ) {
        guard let root = validatedQuarantineRoot(quarantineRoot) else {
            reply("隔离区路径不合法")
            return
        }
        let stored = URL(fileURLWithPath: (storedPath as NSString).standardizingPath)
        guard isStrictlyInside(stored.path, root.path) else {
            reply("源路径不在隔离区内")
            return
        }
        // Same rule as `purge`: a symlink planted inside the store must not be
        // what we move out of it into a privileged location.
        guard !SIPGuard.isSymlink(stored.path) else {
            reply("拒绝还原符号链接")
            return
        }
        // Restoring is a write to a privileged location, so it gets the same
        // treatment as a removal: the destination must be somewhere a
        // privileged rule could have taken it from in the first place.
        guard (try? validatedRemovalDestination(originalPath)) != nil else {
            reply("目标路径不在允许范围内")
            return
        }
        guard !FileManager.default.fileExists(atPath: originalPath) else {
            reply("原位置已有同名文件，未覆盖")
            return
        }

        do {
            let parent = (originalPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: parent, withIntermediateDirectories: true, attributes: nil
            )
            try FileManager.default.moveItem(atPath: stored.path, toPath: originalPath)
            reply(nil)
        } catch {
            reply(error.localizedDescription)
        }
    }

    // MARK: - Purge

    func purge(
        storedPaths: [String],
        quarantineRoot: String,
        withReply reply: @escaping ([String: String]) -> Void
    ) {
        var failures: [String: String] = [:]
        guard let root = validatedQuarantineRoot(quarantineRoot) else {
            for path in storedPaths { failures[path] = "隔离区路径不合法" }
            reply(failures)
            return
        }

        for path in storedPaths {
            let normalized = (path as NSString).standardizingPath
            // The only thing this helper is ever allowed to delete outright is
            // something already inside the quarantine store.
            guard isStrictlyInside(normalized, root.path) else {
                failures[path] = "拒绝删除隔离区之外的路径"
                continue
            }
            guard !SIPGuard.isSymlink(normalized) else {
                failures[path] = "拒绝删除符号链接"
                continue
            }
            do {
                try FileManager.default.removeItem(atPath: normalized)
            } catch {
                failures[path] = error.localizedDescription
            }
        }
        reply(failures)
    }

    // MARK: - Uninstall

    func uninstall(withReply reply: @escaping (Bool) -> Void) {
        NSLog("[MacVitalHelper] uninstall requested")
        reply(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
    }

    // MARK: - Validation

    /// The quarantine root must look exactly like the one the app builds:
    /// `/Users/<name>/Library/Application Support/MacVital/Quarantine`, owned
    /// by that user, and not reachable through a symlink.
    private func validatedQuarantineRoot(_ path: String) -> URL? {
        guard let resolved = SIPGuard.realPath((path as NSString).standardizingPath) else { return nil }
        let components = resolved.split(separator: "/").map(String.init)
        guard components.count == 6,
              components[0] == "Users",
              components[2] == "Library",
              components[3] == "Application Support",
              components[4] == "MacVital",
              components[5] == "Quarantine"
        else { return nil }

        var info = stat()
        guard lstat(resolved, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        // Root-owned quarantine directory would mean someone else planted it.
        guard info.st_uid != 0 else { return nil }
        return URL(fileURLWithPath: resolved)
    }

    /// A path this helper is willing to move out of a privileged location.
    private func validatedRemovalSource(_ path: String) throws -> URL {
        let url = try validatedRemovalDestination(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw HelperServiceError.rejected("路径不存在")
        }
        return url
    }

    /// Shared validation for both directions: it must match a rule that is
    /// explicitly marked as needing privilege, and clear every filesystem guard.
    private func validatedRemovalDestination(_ path: String) throws -> URL {
        let normalized = ProtectedPaths.normalize(path)

        guard !SIPGuard.isSymlink(normalized) else {
            throw HelperServiceError.rejected("拒绝处理符号链接")
        }
        if let flag = SIPGuard.blockingFlag(at: normalized) {
            throw HelperServiceError.rejected("受系统保护（\(flag)），拒绝操作")
        }
        if let reason = protectedPaths.isHardDenied(normalized) {
            throw HelperServiceError.rejected("命中保护规则 \(reason.rawValue)")
        }
        // The decisive check: only paths that a privileged rule in the shared
        // catalog can describe are eligible. Everything else is refused even
        // if the client insists.
        let matched = rules.all.contains { rule in
            rule.requiresPrivilege && rule.pattern.matches(normalized)
        }
        guard matched else {
            throw HelperServiceError.rejected("没有匹配的特权清理规则")
        }
        return URL(fileURLWithPath: normalized)
    }

    private func isStrictlyInside(_ path: String, _ root: String) -> Bool {
        let normalized = ProtectedPaths.normalize(path)
        let normalizedRoot = ProtectedPaths.normalize(root)
        guard normalized != normalizedRoot else { return false }
        guard normalized.hasPrefix(normalizedRoot + "/") else { return false }
        // Reject any traversal that survived normalisation.
        return !normalized.contains("/../")
    }

    /// Hand the moved tree back to the user who owns the quarantine store.
    ///
    /// `lchown`, not `chown`: we are root, and the tree we just moved came from
    /// a privileged location whose contents we did not author. A symlink
    /// anywhere inside it would make `chown` retarget its destination — handing
    /// an arbitrary file on the system to an unprivileged user. `lchown` acts
    /// on the link itself and never follows.
    private func chownToOwner(of reference: URL, path: URL) {
        var info = stat()
        guard lstat(reference.path, &info) == 0 else { return }
        let uid = info.st_uid
        let gid = info.st_gid

        lchown(path.path, uid, gid)
        guard let enumerator = FileManager.default.enumerator(atPath: path.path) else { return }
        for case let relative as String in enumerator {
            lchown(path.appendingPathComponent(relative).path, uid, gid)
        }
    }
}

enum HelperServiceError: LocalizedError {
    case rejected(String)
    var errorDescription: String? {
        switch self {
        case .rejected(let reason): return reason
        }
    }
}
