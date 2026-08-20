import Foundation

/// The five things v1 scans for. Startup items and privacy traces are phase 2.
public enum ScanCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Xcode / node_modules / Pods / Docker / package-manager caches. The biggest
    /// space sink on a developer's Mac and the weakest spot in competing tools.
    case developerResidue
    /// Files left behind by apps that are no longer installed.
    case appResidue
    /// Individual files above a size threshold.
    case largeFiles
    /// Byte-identical copies of the same file.
    case duplicateFiles
    /// Ordinary per-app caches. Table stakes, zero differentiation.
    case caches
    /// Directories containing nothing but other empty directories.
    case emptyFolders
    /// Everything belonging to one app the user has chosen to remove. Produced
    /// by `AppUninstallPlanner`, not by a scanner — the user names the app
    /// first, so this never appears in a sweep.
    case appUninstall

    public var id: String { rawValue }

    /// Whether a full-disk sweep produces this category. `appUninstall` does
    /// not: it is driven by an explicit choice of app, and listing it beside
    /// the sweep categories would imply the scan goes looking for apps to
    /// remove.
    public var isSweepCategory: Bool { self != .appUninstall }

    /// The categories a scan actually walks.
    public static var sweepCategories: [ScanCategory] { allCases.filter(\.isSweepCategory) }

    public var title: String {
        switch self {
        case .developerResidue: return "开发者残留"
        case .appResidue: return "卸载残留"
        case .largeFiles: return "大文件"
        case .duplicateFiles: return "重复文件"
        case .caches: return "缓存"
        case .emptyFolders: return "空文件夹"
        case .appUninstall: return "卸载应用"
        }
    }

    public var symbolName: String {
        switch self {
        case .developerResidue: return "hammer"
        case .appResidue: return "shippingbox"
        case .largeFiles: return "doc.viewfinder"
        case .duplicateFiles: return "doc.on.doc"
        case .caches: return "internaldrive"
        case .emptyFolders: return "folder.badge.minus"
        case .appUninstall: return "trash.square"
        }
    }

    public var blurb: String {
        switch self {
        case .developerResidue:
            return "构建产物、模拟器运行时、依赖目录。有 lock 文件的都能重建。"
        case .appResidue:
            return "已卸载 App 遗留的配置、容器和登录项。"
        case .largeFiles:
            return "占用最多的单个文件，需要你逐个确认。"
        case .duplicateFiles:
            return "内容完全相同的副本，每组会保留一份。"
        case .caches:
            return "App 缓存目录，删除后由 App 自行重建。"
        case .emptyFolders:
            return "什么都不剩的空目录，卸载和搬移之后留下的骨架。"
        case .appUninstall:
            return "选定 App 的程序包及其散落在系统各处的配置、容器和登录项。"
        }
    }

    /// Categories where every item must be individually approved by the user,
    /// no matter what the rule engine and the model say.
    public var requiresExplicitSelection: Bool {
        switch self {
        case .largeFiles, .duplicateFiles: return true
        // 空目录偶尔是程序运行时依赖的挂载点或占位符，逐个确认。
        case .emptyFolders: return true
        // Uninstall items are already the product of an explicit choice — the
        // user named the app — so the tick marks are pre-set. The confirm
        // sheet is still the authorisation step.
        case .developerResidue, .appResidue, .caches, .appUninstall: return false
        }
    }
}
