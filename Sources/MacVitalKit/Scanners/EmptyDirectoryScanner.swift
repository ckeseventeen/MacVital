import Foundation

/// Directories with nothing left in them.
///
/// These are what uninstalling leaves behind after every tool — including this
/// one — has taken the files: `~/Library/Application Support/SomeVendor/` with
/// an empty `Logs/` inside it and nothing else. They cost no meaningful disk
/// space, so this is not a space feature; it is a tidiness feature, and the
/// honest framing in the UI is "骨架", not "可回收 X GB".
///
/// Only the **topmost** empty directory of a run is reported. A vendor folder
/// containing three empty subfolders is one row, not four — removing the parent
/// takes the children with it, and listing all four would let the user tick a
/// child and a parent and then wonder why one of them failed.
public struct EmptyDirectoryScanner: Scanner {
    public let category: ScanCategory = .emptyFolders

    /// Deep enough to reach real residue, shallow enough that a stray symlink
    /// farm cannot turn this into a full-disk walk.
    private let maxDepth = 8

    /// Files that do not make a directory non-empty.
    ///
    /// Finder writes `.DS_Store` into any directory a window has ever been
    /// opened on, and a custom folder icon lives in `Icon\r`. Treating either
    /// as content would hide most genuinely empty folders on a normal Mac —
    /// every other cleaner ignores them for the same reason. It does mean a
    /// removal here deletes those two files, which is why the rationale says so.
    private static let ignorableFiles: Set<String> = [".DS_Store", ".localized", "Icon\r"]

    public init() {}

    public func scan(context: ScanContext, progress: @Sendable (ScanProgress) -> Void) async throws -> [ScanItem] {
        let roots = Self.roots(context: context).filter { FileWalker.exists(URL(fileURLWithPath: $0)) }
        var items: [ScanItem] = []

        for (position, root) in roots.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            progress(ScanProgress(
                category: category,
                message: PathRedaction.abbreviate(root),
                fraction: Double(position) / Double(max(roots.count, 1))
            ))
            await Task.yield()

            let url = URL(fileURLWithPath: root)
            // The root itself is never a candidate, however empty it is:
            // `~/Library/Caches` with nothing in it is a normal state, not
            // residue, and `ProtectedPaths` denies it anyway.
            for child in FileWalker.children(of: url) {
                if Task.isCancelled { throw CancellationError() }
                guard let item = try collect(child, depth: 1) else { continue }
                items.append(item)
            }
        }

        progress(ScanProgress(category: category, message: "完成", fraction: 1.0))
        return items.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Returns an item when `url` is the top of an empty run, nil otherwise.
    private func collect(_ url: URL, depth: Int) throws -> ScanItem? {
        if Task.isCancelled { throw CancellationError() }
        guard depth <= maxDepth else { return nil }
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true,
              // Never look inside a bundle. An app with an empty `Resources/`
              // is not residue, it is a shipped bundle, and proposing pieces of
              // one is how a working app gets broken.
              values.isPackage != true
        else { return nil }

        guard let measurement = try measureEmptiness(url, depth: depth), measurement.isEmpty else { return nil }

        let attributes = FileWalker.attributes(of: url)
        return ScanItem(
            path: ProtectedPaths.normalize(url.path),
            displayName: url.lastPathComponent,
            category: .emptyFolders,
            ruleID: Self.ruleID,
            kindHint: measurement.subdirectoryCount == 0
                ? "空目录"
                : "空目录（含 \(measurement.subdirectoryCount) 个同样为空的子目录）",
            // Reported as zero rather than the few KB the directory entries
            // occupy. Claiming a number here would inflate "可回收" with space
            // that removing them does not return.
            sizeBytes: 0,
            fileCount: 0,
            isDirectory: true,
            lastModified: attributes.modified,
            rebuildable: false
        )
    }

    private struct Emptiness {
        var isEmpty: Bool
        var subdirectoryCount: Int
    }

    /// Recursive, post-order: a directory is empty when it holds no files worth
    /// counting and every subdirectory beneath it is empty too.
    private func measureEmptiness(_ url: URL, depth: Int) throws -> Emptiness? {
        guard depth <= maxDepth else { return nil }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
            options: []
        ) else {
            // Unreadable is not the same as empty. Refusing here is what keeps
            // a permission error from being reported as "nothing inside".
            return nil
        }

        var subdirectories = 0
        for child in contents {
            if Task.isCancelled { throw CancellationError() }
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
            else { return nil }

            // A symlink is content: the directory is not empty, and following
            // it would take us somewhere this scan has no business being.
            if values.isSymbolicLink == true { return Emptiness(isEmpty: false, subdirectoryCount: 0) }

            if values.isDirectory == true, values.isPackage != true {
                guard let nested = try measureEmptiness(child, depth: depth + 1), nested.isEmpty else {
                    return Emptiness(isEmpty: false, subdirectoryCount: 0)
                }
                subdirectories += 1 + nested.subdirectoryCount
                continue
            }

            guard Self.ignorableFiles.contains(child.lastPathComponent) else {
                return Emptiness(isEmpty: false, subdirectoryCount: 0)
            }
        }
        return Emptiness(isEmpty: true, subdirectoryCount: subdirectories)
    }

    // MARK: - Roots

    /// `~/Library` only.
    ///
    /// `~/Documents` and friends are deliberately absent: an empty folder there
    /// is the user's own filing rather than residue, and reaching into it would
    /// need a `allowedInUserData` rule with a home-wide pattern — which is
    /// exactly what `testUserDataOptInIsNarrow` exists to prevent.
    static func roots(context: ScanContext) -> [String] {
        let home = context.home
        return [
            "\(home)/Library/Application Support",
            "\(home)/Library/Containers",
            "\(home)/Library/Group Containers",
            "\(home)/Library/Application Scripts",
            "\(home)/Library/Caches",
            "\(home)/Library/Logs",
            "\(home)/Library/Preferences",
            "\(home)/Library/Saved Application State",
            "\(home)/Library/HTTPStorages",
            "\(home)/Library/WebKit",
        ]
    }

    /// The catalog rule every candidate is filed under. The scanner adds no
    /// authority of its own — `RuleEngine` re-derives it, and a path outside
    /// `~/Library` matches no pattern and is denied.
    static let ruleID = "empty.userLibrary"
}
