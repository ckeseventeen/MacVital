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
        case .unsupported: return "当前系统不支持"
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

    nonisolated public func status() -> HelperStatus {
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

    private func proxy() throws -> MacVitalHelperProtocol {
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

        let remote = connection.remoteObjectProxyWithErrorHandler { error in
            Log.helper.error("xpc error: \(error.localizedDescription, privacy: .public)")
        }
        guard let typed = remote as? MacVitalHelperProtocol else {
            throw HelperError.notConnected
        }
        return typed
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
        let remote = try proxy()
        return await withCheckedContinuation { continuation in
            remote.helperVersion { version in continuation.resume(returning: version) }
        }
    }

    public func moveToQuarantine(
        paths: [String],
        quarantineRoot: String
    ) async throws -> (moved: [String: String], failures: [String: String]) {
        let remote = try proxy()
        return await withCheckedContinuation { continuation in
            remote.moveToQuarantine(paths: paths, quarantineRoot: quarantineRoot) { moved, failures in
                continuation.resume(returning: (moved, failures))
            }
        }
    }

    public func restore(storedPath: String, originalPath: String, quarantineRoot: String) async throws {
        let remote = try proxy()
        let message: String? = await withCheckedContinuation { continuation in
            remote.restore(storedPath: storedPath, originalPath: originalPath, quarantineRoot: quarantineRoot) { error in
                continuation.resume(returning: error)
            }
        }
        if let message { throw HelperError.remote(message) }
    }

    public func purge(storedPaths: [String], quarantineRoot: String) async throws -> [String: String] {
        let remote = try proxy()
        return await withCheckedContinuation { continuation in
            remote.purge(storedPaths: storedPaths, quarantineRoot: quarantineRoot) { failures in
                continuation.resume(returning: failures)
            }
        }
    }

    public func uninstall() async throws {
        let remote = try proxy()
        _ = await withCheckedContinuation { continuation in
            remote.uninstall { ok in continuation.resume(returning: ok) }
        }
        clearConnection()
        try? await unregister()
    }
}

public enum HelperError: LocalizedError {
    case notConnected
    case unverifiedHelper
    case notApproved
    case remote(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "无法连接到特权助手。"
        case .unverifiedHelper: return "无法校验助手程序签名，已拒绝连接。"
        case .notApproved: return "特权助手尚未获得授权，请在系统设置中允许。"
        case .remote(let message): return message
        }
    }
}
