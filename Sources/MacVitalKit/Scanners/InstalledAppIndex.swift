import Foundation

/// Everything currently installed, indexed by the identifiers that residue
/// files are named after.
public struct InstalledAppIndex: Sendable {
    public struct App: Hashable, Sendable {
        public let bundleIdentifier: String
        public let name: String
        public let path: String
    }

    public let apps: [App]
    private let bundleIDs: Set<String>
    /// Reverse-DNS prefixes: `com.acme` for `com.acme.Editor`. A file named
    /// `com.acme.Updater.plist` belongs to a vendor that is still installed.
    private let vendorPrefixes: Set<String>
    /// Every string a support directory might plausibly be named after, mapped
    /// back to the app it belongs to. Three independent sources, because no
    /// single one covers the real world:
    ///
    ///  * the display name — but `CFBundleName` read through `Bundle` is
    ///    *localized*, so 百度网盘 comes back for a directory named
    ///    `baidunetdisk` and never matches,
    ///  * the bundle's own filename on disk, which is not localized
    ///    (`BaiduNetdisk_mac.app`),
    ///  * the words of the bundle identifier (`baidu`, `baidunetdiskmac` from
    ///    `com.baidu.BaiduNetdisk-mac`).
    ///
    /// Sorted so a lookup is deterministic rather than dictionary-order.
    private let matchTokens: [(token: String, app: App)]

    public init(apps: [App]) {
        self.apps = apps
        self.bundleIDs = Set(apps.map { $0.bundleIdentifier.lowercased() })

        var prefixes = Set<String>()
        var tokens: [String: App] = [:]

        func add(_ raw: String, _ app: App) {
            let key = Self.normalize(raw)
            guard key.count >= Self.minimumTokenLength else { return }
            if tokens[key] == nil { tokens[key] = app }
        }

        for app in apps {
            let parts = app.bundleIdentifier.lowercased().split(separator: ".")
            if parts.count >= 2 {
                prefixes.insert(parts.prefix(2).joined(separator: "."))
            }
            add(app.name, app)
            add(URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent, app)
            // Skip parts[0] — that is the `com` / `org` / `io` namespace, and
            // matching on it would swallow every directory named "com".
            for part in parts.dropFirst() { add(String(part), app) }
        }

        self.vendorPrefixes = prefixes
        self.matchTokens = tokens.map { (token: $0.key, app: $0.value) }.sorted { $0.token < $1.token }
    }

    public static func build() -> InstalledAppIndex {
        let roots = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/System/Library/CoreServices",
            "\(PathRedaction.home)/Applications",
        ].map(URL.init(fileURLWithPath:))

        var apps: [App] = []
        var seen = Set<String>()

        func record(_ url: URL) {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
            guard seen.insert(id.lowercased()).inserted else { return }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            apps.append(App(bundleIdentifier: id, name: name, path: url.path))
        }

        for root in roots where FileWalker.exists(root) {
            for child in FileWalker.children(of: root) {
                if child.pathExtension == "app" {
                    record(child)
                    continue
                }
                // Vendors ship suites as a plain folder of apps — Adobe, Microsoft,
                // JetBrains all do it. Missing those apps here is not a cosmetic
                // gap: the residue scanner would then read their support files as
                // belonging to something uninstalled and offer them for removal.
                // One level is enough to cover the convention; going deeper would
                // start walking app bundles' own nested helpers.
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                      !child.lastPathComponent.hasPrefix(".")
                else { continue }
                for grandchild in FileWalker.children(of: child) where grandchild.pathExtension == "app" {
                    record(grandchild)
                }
            }
        }
        return InstalledAppIndex(apps: apps)
    }

    // MARK: - Attribution

    public enum Match: Sendable {
        /// Exact bundle-identifier hit.
        case installed(App)
        /// The vendor is installed but this specific identifier is not — a
        /// renamed helper, an old version, or a shared component.
        case vendorInstalled(String)
        /// Filename resembles an installed app's display name.
        case nameSimilar(App)
        case none
    }

    /// The cheap, deterministic half of attribution. The AI layer picks up the
    /// `.vendorInstalled` and `.none` cases, where filename matching is exactly
    /// what fails today.
    public func match(residueName: String) -> Match {
        let token = Self.identifierToken(from: residueName).lowercased()
        guard !token.isEmpty else { return .none }

        // Shared containers are named `group.<bundleid>` or
        // `<TEAMID>.<bundleid>`, and this matcher did not know it. Every
        // sandboxed app's group container therefore came back `.none` — "no
        // installed app owns this" — and the residue scanner offered it for
        // removal. `group.com.nebula.karing` belongs to Karing, which was
        // installed and running; wiping it made Karing re-initialise from
        // scratch, over and over.
        //
        // `AppUninstallPlanner.name(_:belongsTo:)` has understood both shapes
        // since it was written. This is the same knowledge, on the side that
        // decides whether something is residue at all.
        if let inner = Self.strippedContainerPrefix(token) {
            let unprefixed = match(residueName: inner)
            if case .none = unprefixed {} else { return unprefixed }
        }

        if let app = apps.first(where: { $0.bundleIdentifier.lowercased() == token }) {
            return .installed(app)
        }
        // An identifier hanging off an installed app's own identifier belongs
        // to that app — it is an extension, a helper, an updater.
        //
        // This returned `.vendorInstalled`, which still reaches the user as a
        // finding (labelled "同厂商仍在使用"). But there is nothing ambiguous
        // about `com.google.GeminiMacOS.launcher` while `com.google.GeminiMacOS`
        // is installed: it is Gemini's launcher. A machine-wide audit found
        // twenty-odd such rows — Gemini's launcher, Claude's ShipIt cache,
        // WPS's Finder extension, nine Safari extensions, UURemote's helper —
        // every one of them belonging to an app sitting in /Applications.
        //
        // `AppUninstallPlanner.name(_:belongsTo:)` has always read this shape
        // as "belongs to". The disagreement was the bug, as it was for the
        // `group.` prefix above.
        //
        // The remaining `.vendorInstalled` case is the genuinely ambiguous one:
        // the *vendor* is installed but this exact identifier is not any app —
        // a shared component, or a stale helper from something since removed.
        let parts = token.split(separator: ".")
        if parts.count >= 3 {
            for length in stride(from: parts.count - 1, through: 2, by: -1) {
                let candidate = parts.prefix(length).joined(separator: ".")
                guard let app = apps.first(where: { $0.bundleIdentifier.lowercased() == candidate })
                else { continue }
                return .installed(app)
            }
        }
        if parts.count >= 2 {
            let vendor = parts.prefix(2).joined(separator: ".")
            if vendorPrefixes.contains(vendor) { return .vendorInstalled(vendor) }
        }

        // Everything above needs the directory to be named like a bundle
        // identifier. Under Application Support almost nothing is: the entries
        // are `Google`, `JetBrains`, `baidunetdisk`, `Sublime Text`. Matching
        // those needs plain-word comparison against installed apps, and getting
        // it wrong is the expensive direction — reporting Chrome's profile
        // directory as the leftovers of an uninstalled app invites the user to
        // delete their bookmarks. Over-matching only costs a missed cleanup
        // suggestion, so every check below resolves toward "still installed".
        let normalized = Self.normalize(residueName)
        guard normalized.count >= Self.minimumTokenLength else { return .none }

        // `Google` against `com.google.Chrome`, `JetBrains` against PyCharm's
        // `com.jetbrains.pycharm`.
        if let hit = matchTokens.first(where: { $0.token == normalized }) {
            return .nameSimilar(hit.app)
        }
        // Either side may carry an affix the other drops: `baidunetdisk`
        // against `baidunetdiskmac`, or `Sublime Text 3` against `Sublime Text`.
        if let hit = matchTokens.first(where: {
            $0.token.hasPrefix(normalized) || normalized.hasPrefix($0.token)
        }) {
            return .nameSimilar(hit.app)
        }
        return .none
    }

    public func app(withBundleIdentifier id: String) -> App? {
        apps.first { $0.bundleIdentifier.caseInsensitiveCompare(id) == .orderedSame }
    }

    // MARK: - Helpers

    /// Strip the extension residue files carry: `com.acme.App.plist` ->
    /// `com.acme.App`, `com.acme.App.savedState` -> `com.acme.App`.
    static func identifierToken(from name: String) -> String {
        var token = name
        for suffix in [".plist", ".savedState", ".binarycookies", ".sfl3", ".sfl2"] where token.hasSuffix(suffix) {
            token.removeLast(suffix.count)
        }
        return token
    }

    /// The identifier inside a shared-container name, or nil if there is no
    /// such prefix.
    ///
    /// Exactly two shapes are accepted, both anchored at the first dot: a
    /// literal `group`, or a ten-character alphanumeric team identifier.
    /// Anything else after a dot is another identifier component, not a
    /// prefix — stripping loosely here would let `com.acme` claim
    /// `com.acme.Other`, which is the over-matching this whole file avoids.
    static func strippedContainerPrefix(_ token: String) -> String? {
        guard let dot = token.firstIndex(of: ".") else { return nil }
        let prefix = String(token[token.startIndex..<dot])
        let rest = String(token[token.index(after: dot)...])
        guard !rest.isEmpty else { return nil }

        let isTeamIdentifier = prefix.count == 10 && prefix.allSatisfy { $0.isLetter || $0.isNumber }
        guard isTeamIdentifier || prefix == "group" else { return nil }
        return rest
    }

    /// Below this, a token is too generic to attribute anything with — `go`,
    /// `db`, `ai` would match half the disk.
    static let minimumTokenLength = 4

    static func normalize(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
