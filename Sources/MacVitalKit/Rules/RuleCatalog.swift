import Foundation

/// The complete allowlist. Everything MacVital is capable of removing is in
/// this file. If it is not here, no scanner can propose it and no user gesture
/// can select it.
public enum RuleCatalog {
    public static let all: [CleanupRule] =
        developerResidue + projectArtifacts + appResidue + pluginResidue + caches + userFiles + emptyFolders + appUninstall

    // MARK: - Uninstall

    /// The only thing the uninstaller adds to the allowlist. Everything else it
    /// proposes — preferences, containers, launch agents, caches — is claimed
    /// under the existing `residue.*` and `cache.*` rules, so it inherits their
    /// guards rather than opening new holes.
    ///
    /// Note what is *not* here: `/System/Applications` (caught by the `/System`
    /// prefix), `/Applications/Utilities` and `/Applications/Safari.app` (both
    /// on the hard-deny list). A rule can only ever narrow what the engine
    /// permits, never widen it.
    public static let appUninstall: [CleanupRule] = [
        CleanupRule(
            id: "uninstall.appBundle",
            category: .appUninstall,
            pattern: "/Applications/*.app",
            kind: "应用程序",
            rationale: "应用程序本体。移除后需要重新下载或安装才能再次使用。",
            rebuildable: false,
            autoSelectable: false
        ),
        CleanupRule(
            id: "uninstall.userAppBundle",
            category: .appUninstall,
            pattern: "~/Applications/*.app",
            kind: "应用程序",
            rationale: "安装在个人目录下的应用程序本体。移除后需要重新安装。",
            rebuildable: false,
            autoSelectable: false
        ),
        // The only rule that needed an exemption carved out of the absolute
        // deny list (see `ProtectedPaths.isInstallerReceipt`). A receipt is a
        // .bom plus a .plist recording that a package was installed; removing
        // it makes `pkgutil --pkgs` forget the package and changes nothing
        // else. The pattern cannot reach any sibling directory under
        // /private/var/db, and the exemption in ProtectedPaths is what actually
        // enforces that — this rule only narrows further.
        CleanupRule(
            id: "uninstall.installerReceipt",
            category: .appUninstall,
            pattern: "/private/var/db/receipts/*",
            kind: "安装回执",
            rationale: "安装器留下的记录（.bom / .plist），仅用于 pkgutil 查询安装历史。移除后该包不再出现在安装记录里，不影响任何已安装的软件。",
            rebuildable: false,
            autoSelectable: false,
            requiresPrivilege: true
        ),
    ]

    // MARK: - Developer residue (fixed locations)

    public static let developerResidue: [CleanupRule] = [
        CleanupRule(
            id: "dev.xcode.derivedData",
            category: .developerResidue,
            pattern: "~/Library/Developer/Xcode/DerivedData/*",
            kind: "Xcode DerivedData",
            rationale: "Xcode 的中间编译产物和索引。删除后下次打开工程会全量重新编译并重建索引。",
            rebuildEvidence: ["info.plist"]
        ),
        CleanupRule(
            id: "dev.xcode.archives",
            category: .developerResidue,
            pattern: "~/Library/Developer/Xcode/Archives/*",
            kind: "Xcode Archives",
            rationale: "历史打包归档，含 dSYM。删除后无法再对该版本做崩溃符号化。",
            rebuildable: false,
            autoSelectable: false
        ),
        CleanupRule(
            id: "dev.xcode.deviceSupport.ios",
            category: .developerResidue,
            pattern: "~/Library/Developer/Xcode/iOS DeviceSupport/*",
            kind: "iOS Device Support",
            rationale: "每接一台新 iOS 设备就会生成一份符号缓存。删除后重新连接设备会重新拷贝（几分钟）。"
        ),
        CleanupRule(
            id: "dev.xcode.deviceSupport.watch",
            category: .developerResidue,
            pattern: "~/Library/Developer/Xcode/watchOS DeviceSupport/*",
            kind: "watchOS Device Support",
            rationale: "watchOS 设备符号缓存，重新连接设备时自动重建。"
        ),
        CleanupRule(
            id: "dev.xcode.previews",
            category: .developerResidue,
            pattern: "~/Library/Developer/Xcode/UserData/Previews/**",
            kind: "SwiftUI Previews 缓存",
            rationale: "SwiftUI 预览的编译缓存，下次预览时重建。"
        ),
        CleanupRule(
            id: "dev.coresimulator.caches",
            category: .developerResidue,
            pattern: "~/Library/Developer/CoreSimulator/Caches/**",
            kind: "模拟器缓存",
            rationale: "iOS 模拟器的动态库（dyld）共享缓存。删除后首次启动模拟器会慢十几秒，之后恢复正常。"
        ),
        CleanupRule(
            id: "dev.coresimulator.unavailableRuntimes",
            category: .developerResidue,
            pattern: "~/Library/Developer/CoreSimulator/Profiles/Runtimes/*",
            kind: "模拟器运行时",
            rationale: "已下载的模拟器系统镜像，单个 5-8 GB。删除后需要从 Apple 重新下载。",
            autoSelectable: false
        ),
        CleanupRule(
            id: "dev.xcode.cache",
            category: .developerResidue,
            pattern: "~/Library/Caches/com.apple.dt.Xcode/**",
            kind: "Xcode 缓存",
            rationale: "Xcode 自身的下载缓存和模块缓存，自动重建。"
        ),
        CleanupRule(
            id: "dev.cocoapods.cache",
            category: .developerResidue,
            pattern: "~/Library/Caches/CocoaPods/**",
            kind: "CocoaPods 缓存",
            rationale: "Pod 源码和 spec 仓库缓存。下次 pod install 时按 Podfile.lock 重新拉取。"
        ),
        CleanupRule(
            id: "dev.homebrew.cache",
            category: .developerResidue,
            pattern: "~/Library/Caches/Homebrew/**",
            kind: "Homebrew 下载缓存",
            rationale: "已安装 formula 的下载包。删除不影响已装软件，重装时会重新下载。"
        ),
        CleanupRule(
            id: "dev.npm.cache",
            category: .developerResidue,
            pattern: "~/.npm/_cacache/**",
            kind: "npm 缓存",
            rationale: "npm 的内容寻址包缓存。删除后首次 install 需要联网重新下载。"
        ),
        CleanupRule(
            id: "dev.yarn.cache",
            category: .developerResidue,
            pattern: "~/Library/Caches/Yarn/**",
            kind: "Yarn 缓存",
            rationale: "Yarn 全局包缓存，联网可重建。"
        ),
        CleanupRule(
            id: "dev.pnpm.store",
            category: .developerResidue,
            pattern: "~/Library/pnpm/store/**",
            kind: "pnpm store",
            rationale: "pnpm 的全局硬链接仓库。删除后所有 pnpm 项目的 node_modules 会失效，需要重新 install。",
            autoSelectable: false
        ),
        CleanupRule(
            id: "dev.gradle.caches",
            category: .developerResidue,
            pattern: "~/.gradle/caches/**",
            kind: "Gradle 缓存",
            rationale: "Gradle 依赖和构建缓存，联网可重建。"
        ),
        CleanupRule(
            id: "dev.maven.repository",
            category: .developerResidue,
            pattern: "~/.m2/repository/**",
            kind: "Maven 本地仓库",
            rationale: "Maven 依赖本地副本。删除后首次构建需要重新下载全部依赖，可能很慢。",
            autoSelectable: false
        ),
        CleanupRule(
            id: "dev.cargo.registryCache",
            category: .developerResidue,
            pattern: "~/.cargo/registry/cache/**",
            kind: "Cargo registry 缓存",
            rationale: "Rust crate 压缩包缓存，联网可重建。"
        ),
        CleanupRule(
            id: "dev.go.modcache",
            category: .developerResidue,
            pattern: "~/go/pkg/mod/cache/download/**",
            kind: "Go module 缓存",
            rationale: "Go 模块下载缓存，按 go.sum 可重新拉取。"
        ),
        CleanupRule(
            id: "dev.swiftpm.cache",
            category: .developerResidue,
            pattern: "~/Library/Caches/org.swift.swiftpm/**",
            kind: "SwiftPM 缓存",
            rationale: "Swift Package Manager 的依赖检出缓存，按 Package.resolved 可重建。"
        ),
        CleanupRule(
            id: "dev.pip.cache",
            category: .developerResidue,
            pattern: "~/Library/Caches/pip/**",
            kind: "pip 缓存",
            rationale: "Python wheel 下载缓存，联网可重建。"
        ),
        CleanupRule(
            id: "dev.docker.diskImage",
            category: .developerResidue,
            pattern: "~/Library/Containers/com.docker.docker/Data/vms/*/data/*.raw",
            kind: "Docker 磁盘镜像",
            rationale: "Docker Desktop 的虚拟磁盘。直接删除会连同所有镜像、容器和 volume 一起丢失，且不可恢复。此处仅作展示，请改用 `docker system prune`。",
            rebuildable: false,
            autoSelectable: false
        ),
        CleanupRule(
            id: "dev.docker.buildCache",
            category: .developerResidue,
            pattern: "~/Library/Containers/com.docker.docker/Data/log/**",
            kind: "Docker 日志",
            rationale: "Docker Desktop 的运行日志。"
        ),
    ]

    // MARK: - Developer residue (searched under project roots)

    /// These have no fixed path — the scanner walks configured project roots
    /// looking for directories with these names. `allowedInUserData` is on
    /// because projects legitimately live in ~/Documents and ~/Desktop, and
    /// these four names are unambiguously build output.
    public static let projectArtifacts: [CleanupRule] = [
        CleanupRule(
            id: "dev.project.nodeModules",
            category: .developerResidue,
            pattern: "**/node_modules",
            kind: "node_modules",
            rationale: "Node 依赖目录。存在 lock 文件时可完整重建。",
            allowedInUserData: true,
            projectArtifactName: "node_modules",
            rebuildEvidence: ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "package.json"]
        ),
        CleanupRule(
            id: "dev.project.pods",
            category: .developerResidue,
            pattern: "**/Pods",
            kind: "Pods",
            rationale: "CocoaPods 安装目录。存在 Podfile.lock 时可用 pod install 精确重建。",
            allowedInUserData: true,
            projectArtifactName: "Pods",
            rebuildEvidence: ["Podfile.lock", "Podfile"]
        ),
        CleanupRule(
            id: "dev.project.swiftBuild",
            category: .developerResidue,
            pattern: "**/.build",
            kind: "SwiftPM .build",
            rationale: "Swift Package Manager 构建目录，按 Package.resolved 可重建。",
            allowedInUserData: true,
            projectArtifactName: ".build",
            rebuildEvidence: ["Package.resolved", "Package.swift"]
        ),
        CleanupRule(
            id: "dev.project.cargoTarget",
            category: .developerResidue,
            pattern: "**/target",
            kind: "Cargo target",
            rationale: "Rust 构建输出目录，cargo build 可重建。",
            allowedInUserData: true,
            projectArtifactName: "target",
            rebuildEvidence: ["Cargo.lock", "Cargo.toml"]
        ),
        CleanupRule(
            id: "dev.project.pythonVenv",
            category: .developerResidue,
            pattern: "**/.venv",
            kind: "Python venv",
            rationale: "Python 虚拟环境。存在 requirements.txt 或 pyproject.toml 时可重建。",
            autoSelectable: false,
            allowedInUserData: true,
            projectArtifactName: ".venv",
            rebuildEvidence: ["requirements.txt", "pyproject.toml", "Pipfile.lock", "poetry.lock"]
        ),
        CleanupRule(
            id: "dev.project.nextCache",
            category: .developerResidue,
            pattern: "**/.next",
            kind: "Next.js 构建缓存",
            rationale: "Next.js 的构建输出与缓存，next build 可重建。",
            allowedInUserData: true,
            projectArtifactName: ".next",
            rebuildEvidence: ["next.config.js", "next.config.mjs", "package.json"]
        ),
    ]

    // MARK: - Uninstall residue

    /// Locations where uninstalled apps leave things behind. The residue
    /// scanner produces items here; the AI layer does the attribution work
    /// that pure bundle-ID string matching misses.
    public static let appResidue: [CleanupRule] = [
        CleanupRule(
            id: "residue.applicationSupport",
            category: .appResidue,
            pattern: "~/Library/Application Support/*",
            kind: "Application Support",
            rationale: "App 的支持文件目录。归属的 App 已不在本机。",
            rebuildable: false,
            autoSelectable: false
        ),
        CleanupRule(
            id: "residue.containers",
            category: .appResidue,
            pattern: "~/Library/Containers/*",
            kind: "沙盒容器",
            rationale: "沙盒 App 的私有容器，含其全部文档和设置。归属的 App 已不在本机。",
            rebuildable: false,
            autoSelectable: false
        ),
        CleanupRule(
            id: "residue.groupContainers",
            category: .appResidue,
            pattern: "~/Library/Group Containers/*",
            kind: "共享容器",
            rationale: "App 与其扩展共享的数据容器。",
            rebuildable: false,
            autoSelectable: false
        ),
        CleanupRule(
            id: "residue.preferences",
            category: .appResidue,
            pattern: "~/Library/Preferences/*.plist",
            kind: "偏好设置",
            rationale: "App 的偏好设置文件。"
        ),
        CleanupRule(
            id: "residue.preferencesByHost",
            category: .appResidue,
            pattern: "~/Library/Preferences/ByHost/*.plist",
            kind: "偏好设置（按主机）",
            rationale: "绑定到本机的 App 偏好设置。"
        ),
        CleanupRule(
            id: "residue.savedState",
            category: .appResidue,
            pattern: "~/Library/Saved Application State/*.savedState",
            kind: "窗口状态",
            rationale: "App 的窗口恢复状态，重新打开 App 时重建。"
        ),
        CleanupRule(
            id: "residue.httpStorages",
            category: .appResidue,
            pattern: "~/Library/HTTPStorages/*",
            kind: "网络存储",
            rationale: "App 的 Cookie 和 HTTP 缓存。"
        ),
        CleanupRule(
            id: "residue.applicationScripts",
            category: .appResidue,
            pattern: "~/Library/Application Scripts/*",
            kind: "App 脚本目录",
            rationale: "沙盒 App 及其扩展的脚本目录，随 App 安装创建。归属的 App 已不在本机。",
            rebuildable: false,
            autoSelectable: false
        ),
        CleanupRule(
            id: "residue.webkit",
            category: .appResidue,
            pattern: "~/Library/WebKit/*",
            kind: "WebKit 数据",
            rationale: "内嵌 WebView 的本地存储。"
        ),
        CleanupRule(
            id: "residue.logs",
            category: .appResidue,
            pattern: "~/Library/Logs/*",
            kind: "日志",
            rationale: "App 写入的日志目录。"
        ),
        CleanupRule(
            id: "residue.launchAgents",
            category: .appResidue,
            pattern: "~/Library/LaunchAgents/*.plist",
            kind: "登录项",
            rationale: "用户级后台启动项。归属的 App 已不在本机，该项每次登录都会失败一次。",
            autoSelectable: false
        ),
        CleanupRule(
            id: "residue.systemLaunchAgents",
            category: .appResidue,
            pattern: "/Library/LaunchAgents/*.plist",
            kind: "系统登录项",
            rationale: "系统级后台启动项，需要管理员权限才能移除。",
            autoSelectable: false,
            requiresPrivilege: true
        ),
        CleanupRule(
            id: "residue.systemLaunchDaemons",
            category: .appResidue,
            pattern: "/Library/LaunchDaemons/*.plist",
            kind: "系统守护进程",
            rationale: "系统级守护进程配置，需要管理员权限才能移除。",
            autoSelectable: false,
            requiresPrivilege: true
        ),
        CleanupRule(
            id: "residue.privilegedHelpers",
            category: .appResidue,
            pattern: "/Library/PrivilegedHelperTools/*",
            kind: "特权助手",
            rationale: "App 安装的 root 权限助手程序。",
            autoSelectable: false,
            requiresPrivilege: true
        ),
        CleanupRule(
            id: "residue.systemApplicationSupport",
            category: .appResidue,
            pattern: "/Library/Application Support/*",
            kind: "系统 Application Support",
            rationale: "系统级 App 支持文件，需要管理员权限。",
            rebuildable: false,
            autoSelectable: false,
            requiresPrivilege: true
        ),

        // Added after benchmarking uninstall coverage against AppCleaner and
        // CleanMyMac. Each of these is a location those tools clear and this
        // one did not, which is what made a "clean" uninstall leave things
        // behind. They stay `autoSelectable: false` — the uninstaller pre-ticks
        // by `Kind`, so coverage here does not silently widen a sweep.
        CleanupRule(
            id: "residue.cookies",
            category: .appResidue,
            pattern: "~/Library/Cookies/*",
            kind: "Cookie",
            rationale: "App 存放的 Cookie 文件。",
            autoSelectable: false
        ),
        CleanupRule(
            id: "residue.autosave",
            category: .appResidue,
            pattern: "~/Library/Autosave Information/*",
            kind: "自动保存信息",
            rationale: "App 的自动保存与恢复信息，重新打开 App 时重建。",
            autoSelectable: false
        ),
        CleanupRule(
            id: "residue.crashReports",
            category: .appResidue,
            pattern: "~/Library/Application Support/CrashReporter/*",
            kind: "崩溃日志",
            rationale: "该 App 的崩溃报告，仅供诊断，删除不影响任何功能。",
            autoSelectable: false
        ),
        CleanupRule(
            id: "residue.helpCache",
            category: .appResidue,
            pattern: "~/Library/Caches/com.apple.helpd/*",
            kind: "帮助文档缓存",
            rationale: "系统为该 App 的帮助书生成的索引缓存。",
            autoSelectable: false
        ),
        // Plug-in locations get one rule each, generated from a single list —
        // see `pluginResidue` below. A single `~/Library/**` rule was the first
        // attempt and it was wrong: the whole point of this file is that
        // reading a rule's pattern tells you the complete set of paths it can
        // ever authorise, and a wildcard over all of ~/Library tells you
        // nothing. That the planner happens to only produce plug-in paths today
        // is not a property the catalog enforces.
        CleanupRule(
            id: "residue.systemCaches",
            category: .appResidue,
            pattern: "/Library/Caches/*",
            kind: "系统级缓存",
            rationale: "系统级 App 缓存，需要管理员权限。",
            autoSelectable: false,
            requiresPrivilege: true
        ),
        CleanupRule(
            id: "residue.systemPreferences",
            category: .appResidue,
            pattern: "/Library/Preferences/*",
            kind: "系统级偏好设置",
            rationale: "系统级 App 偏好设置，需要管理员权限。",
            autoSelectable: false,
            requiresPrivilege: true
        ),
    ]

    // MARK: - Caches

    public static let caches: [CleanupRule] = [
        CleanupRule(
            id: "cache.userCaches",
            category: .caches,
            pattern: "~/Library/Caches/*",
            kind: "App 缓存",
            rationale: "App 的缓存目录，删除后由 App 自行重建。"
        ),
        CleanupRule(
            id: "cache.crashReports",
            category: .caches,
            pattern: "~/Library/Logs/DiagnosticReports/*",
            kind: "崩溃报告",
            rationale: "本机崩溃日志。"
        ),
    ]

    /// Cache directories that look ordinary but are not. Excluded by name.
    public static let cacheExclusions: Set<String> = [
        "com.apple.containermanagerd",
        "com.apple.HomeKit",
        "com.apple.iCloudHelper",
        "com.apple.nsurlsessiond",
        "CloudKit",
        "FamilyCircle",
        "com.apple.Safari.SafeBrowsing",
        "com.apple.AMPLibraryAgent",
        // On-device model assets. Nothing breaks if they go, but "cache" is
        // misleading about the cost: rebuilding them is a multi-gigabyte
        // download from Apple, not a few seconds of work. Both were being
        // pre-ticked by default on the machine this was audited on.
        "com.apple.e5rt.e5bundlecache",
        "com.apple.VisualIntelligenceCore",
    ]

    // MARK: - Large & duplicate files

    /// The directories the large-file and duplicate scanners walk, and the
    /// rule id suffix each one is filed under.
    ///
    /// Both rules used to be a single `~/**`, which is the widest pattern in
    /// this file by a distance and told a reader nothing — the opposite of the
    /// property the whole catalog is built on. They are also the two rules with
    /// `allowedInUserData: true`, so the pattern was the *only* thing bounding
    /// them: a scanner emitting `file.large` for something in `~/Library` would
    /// have been admitted.
    ///
    /// One rule per root fixes that, and the scanners resolve their rule from
    /// this list rather than naming an id. A root with no rule is not scanned —
    /// default-deny, applied to configuration as well as to paths.
    public static let userFileRoots: [(suffix: String, relativePath: String)] = [
        ("downloads", "Downloads"),
        ("documents", "Documents"),
        ("desktop",   "Desktop"),
        ("movies",    "Movies"),
        ("pictures",  "Pictures"),
    ]

    /// Generic rules for user-picked files. `autoSelectable` is false and the
    /// category is marked `requiresExplicitSelection`, so nothing here is ever
    /// pre-ticked — the user selects every one by hand.
    public static let userFiles: [CleanupRule] = userFileRoots.flatMap { root -> [CleanupRule] in
        [
            CleanupRule(
                id: "file.large.\(root.suffix)",
                category: .largeFiles,
                pattern: "~/\(root.relativePath)/**",
                kind: "大文件",
                rationale: "超过阈值的单个文件。是否需要保留只有你知道。",
                rebuildable: false,
                autoSelectable: false,
                allowedInUserData: true
            ),
            CleanupRule(
                id: "file.duplicate.\(root.suffix)",
                category: .duplicateFiles,
                pattern: "~/\(root.relativePath)/**",
                kind: "重复文件",
                rationale: "与同组其他文件内容完全一致（SHA-256 校验）。每组会自动保留一份。",
                rebuildable: false,
                autoSelectable: false,
                allowedInUserData: true
            ),
        ]
    }

    /// The rule covering `path` for a user-file category, if any.
    ///
    /// The scanners ask this rather than naming an id, so a configured root
    /// that no rule describes simply is not scanned.
    public static func userFileRule(for path: String, category: ScanCategory) -> CleanupRule? {
        let normalized = ProtectedPaths.normalize(path)
        return userFiles.first { $0.category == category && $0.pattern.matches(normalized) }
    }

    // MARK: - Plug-in residue

    /// The plug-in style locations an app can install into, and the rule id
    /// each one is filed under.
    ///
    /// Generated rather than hand-written so the list of directories exists
    /// exactly once — `AppUninstallPlanner` walks the same list. Every pattern
    /// is a single literal directory plus one wildcard component, so the set of
    /// paths any of these can authorise is exactly "the direct children of that
    /// one directory".
    static let pluginLocations: [(suffix: String, path: String, kind: String)] = [
        ("services",       "~/Library/Services",                    "服务扩展"),
        ("quickLook",      "~/Library/QuickLook",                   "QuickLook 插件"),
        ("internetPlugIns", "~/Library/Internet Plug-Ins",          "浏览器插件"),
        ("preferencePanes", "~/Library/PreferencePanes",            "偏好设置面板"),
        ("screenSavers",   "~/Library/Screen Savers",               "屏幕保护"),
        ("widgets",        "~/Library/Widgets",                     "桌面小组件"),
        ("audioComponents", "~/Library/Audio/Plug-Ins/Components",  "音频单元"),
        ("audioHAL",       "~/Library/Audio/Plug-Ins/HAL",          "音频驱动插件"),
        ("audioVST",       "~/Library/Audio/Plug-Ins/VST",          "VST 插件"),
        ("audioVST3",      "~/Library/Audio/Plug-Ins/VST3",         "VST3 插件"),
        ("spotlight",      "~/Library/Spotlight",                   "Spotlight 导入器"),
        ("mailBundles",    "~/Library/Mail/Bundles",                "邮件插件"),
    ]

    public static let pluginResidue: [CleanupRule] = pluginLocations.map { location in
        CleanupRule(
            id: "residue.plugin.\(location.suffix)",
            category: .appResidue,
            pattern: "\(location.path)/*",
            kind: location.kind,
            rationale: "\(location.kind)，由该 App 安装。归属的 App 已不在本机。",
            rebuildable: false,
            autoSelectable: false
        )
    }

    // MARK: - Empty folders

    /// The `~/Library` directories the empty-folder scanner sweeps, and the
    /// rule id each one is filed under.
    ///
    /// Generated rather than hand-written, and one rule per directory rather
    /// than a single `~/Library/**`, for the reason stated at the top of this
    /// file: reading a rule's pattern has to tell you the complete set of paths
    /// it can ever authorise, and a wildcard over all of `~/Library` tells you
    /// nothing. That the scanner happens to visit only these ten directories
    /// today is not a property the catalog enforced — now it is.
    ///
    /// Same arrangement as `pluginLocations`: the list exists once, and
    /// `EmptyDirectoryScanner` walks it, so a directory cannot be added to the
    /// sweep without a rule appearing alongside it.
    ///
    /// `~/Documents` and friends are deliberately absent. An empty folder there
    /// is the user's own filing rather than residue, and reaching into it would
    /// need an `allowedInUserData` rule with a home-wide pattern — which is
    /// exactly what `testUserDataOptInIsNarrow` exists to prevent.
    public static let emptyFolderRoots: [(suffix: String, relativePath: String)] = [
        ("applicationSupport", "Library/Application Support"),
        ("containers",         "Library/Containers"),
        ("groupContainers",    "Library/Group Containers"),
        ("applicationScripts", "Library/Application Scripts"),
        ("caches",             "Library/Caches"),
        ("logs",               "Library/Logs"),
        ("preferences",        "Library/Preferences"),
        ("savedState",         "Library/Saved Application State"),
        ("httpStorages",       "Library/HTTPStorages"),
        ("webKit",             "Library/WebKit"),
    ]

    public static let emptyFolders: [CleanupRule] = emptyFolderRoots.map { root in
        CleanupRule(
            id: "empty.\(root.suffix)",
            category: .emptyFolders,
            pattern: "~/\(root.relativePath)/**",
            kind: "空目录",
            rationale: "目录下没有任何文件，只剩空的子目录。多半是卸载或搬移之后留下的骨架。删除同时会移除其中的 .DS_Store。",
            rebuildable: false,
            autoSelectable: false
        )
    }
}
