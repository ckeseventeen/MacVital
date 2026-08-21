import Foundation

public struct DirectoryMeasurement: Sendable {
    public var bytes: Int64
    public var fileCount: Int
    public var newestModification: Date?
}

/// Filesystem primitives shared by the scanners. Everything here checks
/// `Task.isCancelled` so a scan stops promptly when the user hits cancel.
public enum FileWalker {
    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        .contentModificationDateKey, .contentAccessDateKey,
        .isPackageKey,
    ]

    /// Recursive size of a directory, in allocated bytes (what the disk
    /// actually gives back). Symlinks are counted as links, never followed.
    ///
    /// Deliberately **without** `.skipsPackageDescendants`. That option was
    /// here and it made this function answer a different question than its
    /// name: anything holding an `.app` reported only the bytes outside the
    /// bundle. `DerivedData/<project>` keeps its build products in
    /// `Build/Products/<config>/*.app`, which is most of its weight, and a
    /// Sparkle-updated app parks `Autoupdate.app` under Application Support —
    /// so the number in "可回收 X GB" was systematically short. Measured on a
    /// synthetic tree: 12 KB reported against 112 KB actually on disk.
    ///
    /// Scanners that must not *propose* pieces of a bundle still say so where
    /// that decision belongs — `LargeFileScanner` and `DuplicateFileScanner`
    /// keep the option on their own enumerators, and `EmptyDirectoryScanner`
    /// checks `isPackage` explicitly.
    public static func measure(_ url: URL) throws -> DirectoryMeasurement {
        var bytes: Int64 = 0
        var count = 0
        var newest: Date?

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: resourceKeys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return DirectoryMeasurement(bytes: 0, fileCount: 0, newestModification: nil)
        }

        for case let child as URL in enumerator {
            if Task.isCancelled { throw CancellationError() }
            guard let values = try? child.resourceValues(forKeys: Set(resourceKeys)) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true { continue }
            let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
            bytes += Int64(size)
            count += 1
            if let modified = values.contentModificationDate {
                if newest == nil || modified > newest! { newest = modified }
            }
        }
        return DirectoryMeasurement(bytes: bytes, fileCount: count, newestModification: newest)
    }

    /// Size of a single entry — file or directory.
    public static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        if values?.isDirectory == true {
            return (try? measure(url).bytes) ?? 0
        }
        return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }

    public static func attributes(of url: URL) -> (isDirectory: Bool, modified: Date?, accessed: Date?) {
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .contentModificationDateKey, .contentAccessDateKey,
        ])
        return (values?.isDirectory ?? false, values?.contentModificationDate, values?.contentAccessDate)
    }

    /// Direct children, sorted, non-recursive. Hidden entries included —
    /// residue lives in dotfiles as often as not.
    public static func children(of url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: resourceKeys,
            options: []
        )) ?? []
    }

    public static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Depth-bounded search for directories with a given name. Used to find
    /// node_modules / Pods / target under the user's project roots without
    /// walking the entire home directory.
    ///
    /// Nested matches are not returned: once `node_modules` is found we do not
    /// descend into it looking for more.
    public static func findDirectories(
        named names: Set<String>,
        under root: URL,
        maxDepth: Int,
        skippingHidden: Bool = true
    ) throws -> [URL] {
        var results: [URL] = []
        var queue: [(url: URL, depth: Int)] = [(root, 0)]

        while let (current, depth) = queue.popLast() {
            if Task.isCancelled { throw CancellationError() }
            // `depth` is the depth of `current`; its children sit one below, so
            // this is the check that keeps the walk inside `maxDepth`. Testing
            // `depth <= maxDepth` here descended one level further than asked.
            guard depth < maxDepth else { continue }

            for child in children(of: current) {
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true,
                      values.isSymbolicLink != true
                else { continue }

                let name = child.lastPathComponent
                if names.contains(name) {
                    results.append(child)
                    continue // do not descend into a match
                }
                // A name in `names` already `continue`d above, so this only
                // ever sees non-matches — the extra `names.contains` it used to
                // carry could never be true.
                if skippingHidden && name.hasPrefix(".") { continue }
                // Never walk into app bundles or other packages.
                if name.hasSuffix(".app") || name.hasSuffix(".framework") || name.hasSuffix(".bundle") { continue }
                queue.append((child, depth + 1))
            }
        }
        return results
    }
}
