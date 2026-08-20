import Foundation

/// What the model is allowed to see. Everything here is metadata plus a small,
/// filtered sample — never file contents wholesale, never a path that still
/// contains the account name.
///
/// This is the input that makes semantic attribution work where bundle-ID
/// string matching fails: the filename alone is ambiguous, but filename +
/// sibling names + the top-level plist keys usually is not.
public struct AIEvidence: Codable, Hashable, Sendable {
    public var itemID: UUID
    /// Home collapsed to `~`, username replaced with `<user>`.
    public var redactedPath: String
    public var kindHint: String
    public var ruleRationale: String
    public var sizeBytes: Int64
    public var fileCount: Int
    public var isDirectory: Bool
    public var ageInDays: Int?
    /// A handful of child names, redacted.
    public var childNames: [String]
    /// Top-level keys from a plist, which name the vendor far more reliably
    /// than the filename does.
    public var plistKeys: [String]
    /// Values of the identifying plist keys, when they are short strings.
    public var plistIdentityValues: [String: String]
    /// First bytes of a small text file, printable characters only.
    public var headSnippet: String?
    /// Deterministic attribution result, so the model can agree or disagree
    /// rather than start from nothing.
    public var deterministicOwner: String?
    /// Whether a lock/manifest file proving rebuildability was found.
    public var rebuildEvidence: String?

    public init(
        itemID: UUID,
        redactedPath: String,
        kindHint: String,
        ruleRationale: String,
        sizeBytes: Int64,
        fileCount: Int,
        isDirectory: Bool,
        ageInDays: Int?,
        childNames: [String] = [],
        plistKeys: [String] = [],
        plistIdentityValues: [String: String] = [:],
        headSnippet: String? = nil,
        deterministicOwner: String? = nil,
        rebuildEvidence: String? = nil
    ) {
        self.itemID = itemID
        self.redactedPath = redactedPath
        self.kindHint = kindHint
        self.ruleRationale = ruleRationale
        self.sizeBytes = sizeBytes
        self.fileCount = fileCount
        self.isDirectory = isDirectory
        self.ageInDays = ageInDays
        self.childNames = childNames
        self.plistKeys = plistKeys
        self.plistIdentityValues = plistIdentityValues
        self.headSnippet = headSnippet
        self.deterministicOwner = deterministicOwner
        self.rebuildEvidence = rebuildEvidence
    }
}

/// Reads the small amount of the filesystem the model needs, and nothing more.
public enum EvidenceCollector {
    private static let maxChildNames = 24
    private static let maxPlistKeys = 20
    private static let maxSnippetBytes = 384

    /// Plist keys that actually identify a vendor. Everything else is noise.
    private static let identityKeys: Set<String> = [
        "CFBundleIdentifier", "CFBundleName", "CFBundleDisplayName",
        "Label", "ProgramArguments", "BundleID", "bundleIdentifier",
        "com.apple.LaunchServices.Bundleidentifier", "NSPrincipalClass",
    ]

    public static func collect(for item: ScanItem, rule: CleanupRule?) -> AIEvidence {
        var childNames: [String] = []
        var plistKeys: [String] = []
        var identityValues: [String: String] = [:]
        var snippet: String?

        if item.isDirectory {
            childNames = FileWalker.children(of: item.url)
                .prefix(maxChildNames)
                .map { PathRedaction.redactName($0.lastPathComponent) }

            // A plist inside the directory names the owner far more often than
            // the directory name does.
            if let plist = FileWalker.children(of: item.url).first(where: { $0.pathExtension == "plist" }) {
                let parsed = readPlist(at: plist)
                plistKeys = parsed.keys
                identityValues = parsed.identity
            }
        } else if item.url.pathExtension == "plist" {
            let parsed = readPlist(at: item.url)
            plistKeys = parsed.keys
            identityValues = parsed.identity
        } else if mayReadHead(of: item) {
            snippet = readHead(of: item.url)
        }

        return AIEvidence(
            itemID: item.id,
            redactedPath: PathRedaction.redact(item.path),
            kindHint: item.kindHint,
            ruleRationale: rule?.rationale ?? "",
            sizeBytes: item.sizeBytes,
            fileCount: item.fileCount,
            isDirectory: item.isDirectory,
            ageInDays: item.ageInDays,
            childNames: childNames,
            plistKeys: plistKeys,
            plistIdentityValues: identityValues,
            headSnippet: snippet,
            deterministicOwner: item.ownerHint?.label,
            rebuildEvidence: item.rebuildable ? "找到可重建依据" : nil
        )
    }

    /// Whether a head snippet may be collected for this item at all.
    ///
    /// The snippet exists to attribute residue: a config file left in
    /// `~/Library` usually names its vendor in the first line, and that is the
    /// case bundle-ID matching fails on. It is worth 384 bytes.
    ///
    /// It is not worth anything for the user's own files, and those are exactly
    /// the ones where it is dangerous. `largeFiles` and `duplicateFiles` walk
    /// `~/Documents`, `~/Desktop`, `~/Downloads`, `~/Movies` and `~/Pictures` —
    /// so with the cloud advisor enabled, the opening lines of a user's `.csv`,
    /// `.md`, `.json`, `.log` or `.env` were being sent to a remote API. The
    /// binary filter was never protection here: a text file *is* the content,
    /// and text is where the secrets are.
    ///
    /// Nothing is lost by refusing. What the model is asked about a large file
    /// is "what is this", which the extension, the size and the path already
    /// answer — the categories are also `requiresExplicitSelection`, so the
    /// user reads every one of them regardless.
    static func mayReadHead(of item: ScanItem) -> Bool {
        switch item.category {
        case .largeFiles, .duplicateFiles:
            return false
        case .developerResidue, .appResidue, .caches, .emptyFolders, .appUninstall:
            // Even in these categories, only inside ~/Library. A project
            // artifact rule may reach into ~/Documents, and a stray file there
            // is the user's, not an app's.
            return ProtectedPaths.normalize(item.path)
                .hasPrefix(ProtectedPaths.normalize("\(PathRedaction.home)/Library") + "/")
        }
    }

    private static func readPlist(at url: URL) -> (keys: [String], identity: [String: String]) {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count < 4_000_000,
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any]
        else { return ([], [:]) }

        let keys = Array(dictionary.keys.sorted().prefix(maxPlistKeys))
        var identity: [String: String] = [:]
        for key in keys where identityKeys.contains(key) {
            if let value = dictionary[key] as? String, value.count < 200 {
                identity[key] = PathRedaction.redact(value)
            } else if let array = dictionary[key] as? [String], let first = array.first, first.count < 200 {
                identity[key] = PathRedaction.redact(first)
            }
        }
        return (keys, identity)
    }

    private static func readHead(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxSnippetBytes), !data.isEmpty else { return nil }

        // Only forward text. Binary heads are noise and can carry secrets.
        let printable = data.filter { $0 == 0x0A || $0 == 0x09 || (0x20...0x7E).contains($0) }
        guard printable.count > data.count * 8 / 10 else { return nil }
        return String(decoding: printable, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
