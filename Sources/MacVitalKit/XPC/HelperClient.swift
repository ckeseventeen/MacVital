import Foundation
import ServiceManagement

public enum HelperStatus: Equatable, Sendable {
    case notRegistered
    case requiresApproval
    case enabled
    case notFound
    case unsupported

    public var isUsable: Bool { self == .enabled }

    public var summary: String {
        switch self {
        case .notRegistered: return "未安装"
        case .requiresApproval: return "等待在「系统设置 → 通用 → 登录项」中允许"
        case .enabled: return "已就绪"
        case .notFound: return "未找到助手程序（安装包可能不完整）"
        case .unsupported: return "此构建不可用（需要 Developer ID 签名）"
        }
    }
}

/// Client side of the privileged channel.
///
/// The main app never runs as root. When a removal needs it — /Library,
/// LaunchDaemons, PrivilegedHelperTools — the work is handed to a helper
/// registered through `SMAppService`, which the user approves once in System
/// Settings and can revoke at any time.
public actor HelperClient {
    private var connection: NSXPCConnection?

    public init() {}

    // MARK: - Registration

    nonisolated public var service: SMAppService {
        SMAppService.daemon(plistName: HelperConstants.daemonPlistName)
    }

    /// Whether the privileged helper can work *at all* on this build.
    ///
    /// The XPC connection is pinned to a code-signing requirement derived from
    /// the running app's own team identifier. A self-signed build has none, so
    /// `proxy()` refuses to connect — every privileged operation fails, on
    /// every attempt, forever. That is by design, but it is a property of the
    /// build rather than of anything the user did, and until now the only way
    /// to discover it was to click something and read a message about code
    /// signing.
    nonisolated public static var isSupportedByThisBuild: Bool {
        CodeRequirement.forHelper() != nil
    }

    nonisolated public func status() -> HelperStatus {
        // A build that can never verify the helper reports `unsupported`
        // outright rather than `notRegistered`, which invites the user to
        // install something that will not work.
        guard Self.isSupportedByThisBuild else { return .unsupported }
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unsupported
        }
    }

    /// Registering surfaces a system prompt. Only call it in response to an
    /// explicit user action — never speculatively on launch.
    nonisolated public func register() throws {
        try service.register()
    }

    nonisolated public func unregister() async throws {
        try await service.unregister()
    }

    /// Opens System Settings at the Login Items pane so the user can approve.
    nonisolated public func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Connection

    private func proxy() throws -> NSXPCConnection {
        if connection == nil {
            let new = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
            new.remoteObjectInterface = NSXPCInterface(with: MacVitalHelperProtocol.self)

            // Public API since macOS 13. This is what stops us from talking to
            // an impostor that grabbed the mach service name first.
            if let requirement = CodeRequirement.forHelper() {
                new.setCodeSigningRequirement(requirement)
            } else {
                Log.helper.error("could not derive team identifier; refusing to connect unverified")
                throw HelperError.unverifiedHelper
            }

            new.invalidationHandler = { [weak self] in
                Task { await self?.clearConnection() }
            }
            new.interruptionHandler = { [weak self] in
                Task { await self?.clearConnection() }
            }
            new.resume()
            connection = new
        }
        guard let connection else { throw HelperError.notConnected }
        return connection
    }

    /// Runs one XPC call and resumes exactly once, whichever way it ends.
    ///
    /// The reply block and the connection's error handler are mutually
    /// exclusive but neither is guaranteed: if the daemon is not registered,
    /// not approved, or fails the code-signing requirement, the message is
    /// never delivered and only the error handler fires. That handler used to
    /// do nothing but log, so the `withCheckedContinuation` around the reply
    /// was never resumed and the caller hung forever — the cleanup loop with
    /// it, leaving the UI stuck mid-progress with no cancel.
    ///
    /// The `resumed` flag is not defensive padding either: XPC can in principle
    /// deliver both, and resuming a checked continuation twice is a crash.
    private func call<T: Sendable>(
        _ body: @escaping @Sendable (MacVitalHelperProtocol, @escaping @Sendable (T) -> Void) -> Void
    ) async throws -> T {
        let connection = try proxy()
        let resumed = ResumeGuard()

        return try await withCheckedThrowingContinuation { continuation in
            let remote = connection.remoteObjectProxyWithErrorHandler { error in
                Log.helper.error("xpc error: \(error.localizedDescription, privacy: .public)")
                guard resumed.claim() else { return }
                continuation.resume(throwing: HelperError.transport(error.localizedDescription))
            }
            guard let typed = remote as? MacVitalHelperProtocol else {
                guard resumed.claim() else { return }
                continuation.resume(throwing: HelperError.notConnected)
                return
            }
            body(typed) { value in
                guard resumed.claim() else { return }
                continuation.resume(returning: value)
            }
        }
    }

    private func clearConnection() {
        connection?.invalidate()
        connection = nil
    }

    public func disconnect() {
        clearConnection()
    }

    // MARK: - Operations

    public func version() async throws -> String {
        try await call { remote, reply in
            remote.helperVersion { reply($0) }
        }
    }

    public func moveToQuarantine(
        paths: [String],
        quarantineRoot: String
    ) async throws -> (moved: [String: String], failures: [String: String]) {
        let result: MoveResult = try await call { remote, reply in
            remote.moveToQuarantine(paths: paths, quarantineRoot: quarantineRoot) { moved, failures in
                reply(MoveResult(moved: moved, failures: failures))
            }
        }
        return (result.moved, result.failures)
    }

    public func restore(storedPath: String, originalPath: String, quarantineRoot: String) async throws {
        let message: String? = try await call { remote, reply in
            remote.restore(storedPath: storedPath, originalPath: originalPath, quarantineRoot: quarantineRoot) {
                reply($0)
            }
        }
        if let message { throw HelperError.remote(message) }
    }

    public func purge(storedPaths: [String], quarantineRoot: String) async throws -> [String: String] {
        try await call { remote, reply in
            remote.purge(storedPaths: storedPaths, quarantineRoot: quarantineRoot) { reply($0) }
        }
    }

    public func uninstall() async throws {
        // A helper that cannot be reached is already uninstalled as far as the
        // caller is concerned; unregistering is what actually matters.
        _ = try? await call { (remote: MacVitalHelperProtocol, reply: @escaping @Sendable (Bool) -> Void) in
            remote.uninstall { reply($0) }
        }
        clearConnection()
        try? await unregister()
    }
}

/// The tuple `moveToQuarantine` replies with, as a `Sendable` value so it can
/// cross the continuation.
private struct MoveResult: Sendable {
    let moved: [String: String]
    let failures: [String: String]
}

/// One-shot claim, so a continuation is resumed exactly once no matter which
/// of the two callbacks arrives (or if both do).
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !used else { return false }
        used = true
        return true
    }
}

public enum HelperError: LocalizedError {
    case notConnected
    case unverifiedHelper
    case notApproved
    case remote(String)
    /// The message never reached the helper — not registered, not approved, or
    /// the code-signing requirement was not met.
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "无法连接到特权助手。"
        // Says what it is and what to do. The old text — "无法校验助手程序签名，
        // 已拒绝连接。" — described the mechanism and left the user clicking the
        // same button every two seconds, which is exactly what the logs showed.
        case .unverifiedHelper:
            return "这个构建无法使用特权助手：它是自签名的，拿不到 team identifier，"
                 + "而助手只接受能验明身份的调用方。需要用 Developer ID 证书签名的构建才能启用。"
                 + "涉及系统目录的项目请在访达中手动处理。"
        case .notApproved: return "特权助手尚未获得授权，请在系统设置中允许。"
        case .remote(let message): return message
        case .transport(let detail):
            return "无法与特权助手通信：\(detail)。"
                 + "请确认助手已安装，并已在「系统设置 → 通用 → 登录项」中允许。"
        }
    }
}
