import Darwin
import Foundation
import MacVitalKit

@_silgen_name("removefileat")
private func systemRemoveFileAt(
    _ directory: Int32,
    _ path: UnsafePointer<CChar>,
    _ state: OpaquePointer?,
    _ flags: UInt32
) -> Int32

// `REMOVEFILE_RECURSIVE_SLIM` is an alternative to
// `REMOVEFILE_RECURSIVE`, not a modifier for it. Passing both is undocumented
// and can fail with EINVAL, leaving sealed quarantine containers undeletable.
private let removeRecursively = UInt32(1 << 11)

/// Runs as root and treats every argument, including paths inside quarantine,
/// as hostile input. Filesystem operations are descriptor-relative so an
/// unprivileged client cannot redirect them by swapping an ancestor symlink.
final class HelperService: NSObject, MacVitalHelperProtocol {
    private static let provenanceAttribute = "com.macvital.quarantine.original"
    private static let secureRenameFlags = UInt32(
        RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH
    )

    private let clientUID: uid_t
    private let protectedPaths = ProtectedPaths(home: "/var/empty")
    private let rules = RuleIndex()

    init(clientUID: uid_t) {
        self.clientUID = clientUID
        super.init()
    }

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

        guard let quarantine = try? validatedQuarantineRoot(quarantineRoot) else {
            for path in paths { failures[path] = "隔离区路径不合法或不属于当前用户" }
            reply(moved, failures)
            return
        }

        for path in paths {
            do {
                let source = try validatedRemovalSource(path)
                let stage = try makeStagingDirectory()
                var sourceIsStaged = false
                var stageIsPublished = false
                var preserveStageForRecovery = false

                defer {
                    if !stageIsPublished && !preserveStageForRecovery {
                        _ = Self.removeTree(at: stage.parent.value, name: stage.name)
                    }
                }

                guard Self.secureRename(
                    from: source.parent.value,
                    name: source.name,
                    to: stage.directory.value,
                    name: source.name
                ) == 0 else {
                    throw posixError("无法移入安全暂存区")
                }
                sourceIsStaged = true

                do {
                    try seal(stage.directory.value, originalPath: source.path)
                    let identifier = UUID().uuidString
                    guard Self.secureRename(
                        from: stage.parent.value,
                        name: stage.name,
                        to: quarantine.items.value,
                        name: identifier
                    ) == 0 else {
                        throw posixError("无法发布隔离容器")
                    }
                    stageIsPublished = true
                    sourceIsStaged = false

                    // Keep the container root-owned and inaccessible. The app
                    // only needs its manifest path; restore and purge return to
                    // this helper. This prevents a client from replacing the
                    // payload and asking root to install arbitrary content.
                    _ = fchmod(stage.directory.value, mode_t(0o700))

                    let destination = quarantine.root
                        .appendingPathComponent("Items", isDirectory: true)
                        .appendingPathComponent(identifier, isDirectory: true)
                        .appendingPathComponent(source.name)
                    moved[path] = destination.path
                    NSLog("[MacVitalHelper] quarantined %@", source.name)
                } catch {
                    if sourceIsStaged {
                        let rollback = Self.secureRename(
                            from: stage.directory.value,
                            name: source.name,
                            to: source.parent.value,
                            name: source.name
                        )
                        if rollback != 0 {
                            // The original move succeeded, so deleting the
                            // staging directory here would turn a recoverable
                            // rollback failure into data loss. Keep the
                            // root-only staging directory for manual recovery.
                            preserveStageForRecovery = true
                            throw HelperServiceError.rejected(
                                "隔离失败且无法回滚，文件保留在受保护的暂存区：\(error.localizedDescription)"
                            )
                        }
                    }
                    throw error
                }
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
        do {
            let quarantine = try validatedQuarantineRoot(quarantineRoot)
            let stored = try validatedStoredItem(storedPath, in: quarantine)
            let original = ProtectedPaths.normalize(originalPath)

            guard try readSeal(stored.container.value) == original else {
                throw HelperServiceError.rejected("隔离凭据与原位置不匹配")
            }
            let destination = try validatedRestoreDestination(original)

            guard Self.secureRename(
                from: stored.container.value,
                name: stored.name,
                to: destination.parent.value,
                name: destination.name
            ) == 0 else {
                throw posixError("无法还原文件")
            }

            _ = unlinkat(quarantine.items.value, stored.identifier, AT_REMOVEDIR)
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
        do {
            let quarantine = try validatedQuarantineRoot(quarantineRoot)
            for path in storedPaths {
                do {
                    let identifier = try validatedContainerIdentifier(path, in: quarantine)
                    let container = try openSealedContainer(identifier, in: quarantine)
                    _ = try readSeal(container.value)

                    guard Self.removeTree(at: quarantine.items.value, name: identifier) == 0 else {
                        throw posixError("无法清除隔离容器")
                    }
                } catch {
                    failures[path] = error.localizedDescription
                }
            }
        } catch {
            for path in storedPaths { failures[path] = error.localizedDescription }
        }
        reply(failures)
    }

    func uninstall(withReply reply: @escaping (Bool) -> Void) {
        NSLog("[MacVitalHelper] uninstall requested")
        reply(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
    }

    // MARK: - Validation

    private func validatedQuarantineRoot(_ path: String) throws -> OpenedQuarantine {
        guard clientUID != 0 else {
            throw HelperServiceError.rejected("拒绝 root 客户端")
        }
        let declared = ProtectedPaths.normalize(path)
        guard let account = getpwuid(clientUID), let homePointer = account.pointee.pw_dir else {
            throw HelperServiceError.rejected("无法确认调用者的用户目录")
        }
        let expected = URL(fileURLWithPath: String(cString: homePointer), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MacVital", isDirectory: true)
            .appendingPathComponent("Quarantine", isDirectory: true)
        guard declared == ProtectedPaths.normalize(expected.path) else {
            throw HelperServiceError.rejected("隔离区不属于当前调用者的用户目录")
        }
        guard let resolved = SIPGuard.realPath(declared),
              ProtectedPaths.normalize(resolved) == declared
        else {
            throw HelperServiceError.rejected("隔离区包含符号链接")
        }

        let root = try openDirectoryNoFollow(declared)
        var rootInfo = stat()
        guard fstat(root.value, &rootInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR,
              rootInfo.st_uid == clientUID
        else {
            throw HelperServiceError.rejected("隔离区所有者不是当前用户")
        }

        let itemsFD = openat(
            root.value,
            "Items",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard itemsFD >= 0 else { throw posixError("无法打开隔离项目目录") }
        let items = FileDescriptor(itemsFD)
        var itemsInfo = stat()
        guard fstat(items.value, &itemsInfo) == 0,
              (itemsInfo.st_mode & S_IFMT) == S_IFDIR,
              itemsInfo.st_uid == clientUID
        else {
            throw HelperServiceError.rejected("隔离项目目录所有者异常")
        }

        return OpenedQuarantine(
            root: URL(fileURLWithPath: declared),
            rootDescriptor: root,
            items: items
        )
    }

    private func validatedRemovalSource(_ path: String) throws -> OpenedLocation {
        let normalized = try validatedRulePath(path)
        guard let resolved = SIPGuard.realPath(normalized),
              ProtectedPaths.normalize(resolved) == normalized
        else {
            throw HelperServiceError.rejected("源路径包含符号链接或已不存在")
        }

        let location = try openLocation(normalized)
        var info = stat()
        guard fstatat(location.parent.value, location.name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw posixError("源路径不存在")
        }
        guard (info.st_mode & S_IFMT) != S_IFLNK else {
            throw HelperServiceError.rejected("拒绝处理符号链接")
        }
        if let blocker = SIPGuard.removalBlocker(at: normalized, maxEntries: nil) {
            throw HelperServiceError.rejected("内容受保护，无法安全移除：\(blocker.path)")
        }
        return location
    }

    private func validatedRestoreDestination(_ path: String) throws -> OpenedLocation {
        let normalized = try validatedRulePath(path)
        let location = try openLocation(normalized)
        var info = stat()
        if fstatat(location.parent.value, location.name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            throw HelperServiceError.rejected("原位置已有同名文件，未覆盖")
        }
        guard errno == ENOENT else { throw posixError("无法验证还原目标") }
        return location
    }

    private func validatedRulePath(_ path: String) throws -> String {
        let normalized = ProtectedPaths.normalize(path)
        if let flag = SIPGuard.blockingFlag(at: normalized) {
            throw HelperServiceError.rejected("受系统保护（\(flag)），拒绝操作")
        }
        if let reason = protectedPaths.isHardDenied(normalized) {
            throw HelperServiceError.rejected("命中保护规则 \(reason.rawValue)")
        }
        guard rules.all.contains(where: {
            $0.requiresPrivilege && $0.pattern.matches(normalized)
        }) else {
            throw HelperServiceError.rejected("没有匹配的特权清理规则")
        }
        return normalized
    }

    private func validatedStoredItem(
        _ path: String,
        in quarantine: OpenedQuarantine
    ) throws -> OpenedStoredItem {
        let relative = try quarantineComponents(path, root: quarantine.root.path)
        guard relative.count == 3,
              relative[0] == "Items",
              UUID(uuidString: relative[1]) != nil
        else {
            throw HelperServiceError.rejected("隔离项目路径格式不合法")
        }
        let container = try openSealedContainer(relative[1], in: quarantine)
        var info = stat()
        guard fstatat(container.value, relative[2], &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw posixError("隔离项目已不存在")
        }
        guard (info.st_mode & S_IFMT) != S_IFLNK else {
            throw HelperServiceError.rejected("拒绝还原符号链接")
        }
        return OpenedStoredItem(
            identifier: relative[1],
            name: relative[2],
            container: container
        )
    }

    private func validatedContainerIdentifier(
        _ path: String,
        in quarantine: OpenedQuarantine
    ) throws -> String {
        let relative = try quarantineComponents(path, root: quarantine.root.path)
        guard relative.count == 2,
              relative[0] == "Items",
              UUID(uuidString: relative[1]) != nil
        else {
            throw HelperServiceError.rejected("只能清除完整的隔离容器")
        }
        return relative[1]
    }

    private func openSealedContainer(
        _ identifier: String,
        in quarantine: OpenedQuarantine
    ) throws -> FileDescriptor {
        let fd = openat(
            quarantine.items.value,
            identifier,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard fd >= 0 else { throw posixError("无法打开隔离容器") }
        let descriptor = FileDescriptor(fd)
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == 0
        else {
            throw HelperServiceError.rejected("隔离容器不是助手创建的受保护容器")
        }
        return descriptor
    }

    private func quarantineComponents(_ path: String, root: String) throws -> [String] {
        let normalized = ProtectedPaths.normalize(path)
        guard normalized.hasPrefix(root + "/") else {
            throw HelperServiceError.rejected("路径不在隔离区内")
        }
        let suffix = String(normalized.dropFirst(root.count + 1))
        let components = suffix.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw HelperServiceError.rejected("隔离路径包含非法组件")
        }
        return components
    }

    // MARK: - Descriptor helpers

    private func openDirectoryNoFollow(_ path: String) throws -> FileDescriptor {
        let normalized = ProtectedPaths.normalize(path)
        guard normalized.hasPrefix("/") else {
            throw HelperServiceError.rejected("路径必须为绝对路径")
        }
        var current = FileDescriptor(open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC))
        guard current.value >= 0 else { throw posixError("无法打开根目录") }

        for component in normalized.split(separator: "/").map(String.init) {
            guard component != "." && component != ".." else {
                throw HelperServiceError.rejected("路径包含非法组件")
            }
            let next = openat(
                current.value,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard next >= 0 else { throw posixError("无法安全打开目录") }
            current = FileDescriptor(next)
        }
        return current
    }

    private func openLocation(_ path: String) throws -> OpenedLocation {
        let normalized = ProtectedPaths.normalize(path)
        let name = (normalized as NSString).lastPathComponent
        guard !name.isEmpty && name != "." && name != ".." else {
            throw HelperServiceError.rejected("文件名不合法")
        }
        let parentPath = (normalized as NSString).deletingLastPathComponent
        return OpenedLocation(
            path: normalized,
            name: name,
            parent: try openDirectoryNoFollow(parentPath)
        )
    }

    private func makeStagingDirectory() throws -> StagingDirectory {
        let parentPath = "/private/var/tmp"
        let parent = try openDirectoryNoFollow(parentPath)
        var template = Array("\(parentPath)/.macvital-helper.XXXXXX".utf8CString)
        let created = template.withUnsafeMutableBufferPointer { buffer in
            mkdtemp(buffer.baseAddress) != nil
        }
        guard created else { throw posixError("无法创建安全暂存区") }
        let path = String(cString: template)
        let name = (path as NSString).lastPathComponent
        let fd = openat(parent.value, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            _ = Self.removeTree(at: parent.value, name: name)
            throw posixError("无法打开安全暂存区")
        }
        _ = fchmod(fd, mode_t(0o700))
        return StagingDirectory(name: name, parent: parent, directory: FileDescriptor(fd))
    }

    private func seal(_ descriptor: Int32, originalPath: String) throws {
        let bytes = Array(originalPath.utf8)
        let result = bytes.withUnsafeBytes { buffer in
            fsetxattr(
                descriptor,
                Self.provenanceAttribute,
                buffer.baseAddress,
                buffer.count,
                0,
                0
            )
        }
        guard result == 0 else { throw posixError("无法写入隔离凭据") }
    }

    private func readSeal(_ descriptor: Int32) throws -> String {
        let length = fgetxattr(descriptor, Self.provenanceAttribute, nil, 0, 0, 0)
        guard length > 0, length <= Int(PATH_MAX) else {
            throw HelperServiceError.rejected("隔离容器缺少有效凭据")
        }
        var bytes = [UInt8](repeating: 0, count: length)
        let read = bytes.withUnsafeMutableBytes { buffer in
            fgetxattr(
                descriptor,
                Self.provenanceAttribute,
                buffer.baseAddress,
                buffer.count,
                0,
                0
            )
        }
        guard read == length, let value = String(bytes: bytes, encoding: .utf8) else {
            throw HelperServiceError.rejected("隔离凭据损坏")
        }
        return value
    }

    private static func secureRename(
        from sourceDirectory: Int32,
        name sourceName: String,
        to destinationDirectory: Int32,
        name destinationName: String
    ) -> Int32 {
        renameatx_np(
            sourceDirectory,
            sourceName,
            destinationDirectory,
            destinationName,
            secureRenameFlags
        )
    }

    private static func removeTree(at directory: Int32, name: String) -> Int32 {
        name.withCString { path in
            systemRemoveFileAt(directory, path, nil, removeRecursively)
        }
    }

    private func posixError(_ operation: String) -> HelperServiceError {
        let detail = String(cString: strerror(errno))
        return .rejected("\(operation)：\(detail)")
    }
}

private final class FileDescriptor {
    let value: Int32

    init(_ value: Int32) {
        self.value = value
    }

    deinit {
        if value >= 0 { _ = Darwin.close(value) }
    }
}

private struct OpenedQuarantine {
    let root: URL
    let rootDescriptor: FileDescriptor
    let items: FileDescriptor
}

private struct OpenedLocation {
    let path: String
    let name: String
    let parent: FileDescriptor
}

private struct OpenedStoredItem {
    let identifier: String
    let name: String
    let container: FileDescriptor
}

private struct StagingDirectory {
    let name: String
    let parent: FileDescriptor
    let directory: FileDescriptor
}

private enum HelperServiceError: LocalizedError {
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .rejected(let reason): return reason
        }
    }
}
