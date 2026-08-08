import Foundation

/// A small, deliberately limited glob matcher for absolute paths.
///
/// Supported syntax:
///   - `~`  expands to the home directory at parse time
///   - `*`  matches within a single path component ("*.plist", "com.apple.*")
///   - `**` matches zero or more whole components
///
/// Deliberately *not* supported: `?`, character classes, brace expansion,
/// negation. Every unsupported construct is one more way to write a rule that
/// matches more than its author intended.
public struct PathPattern: Hashable, Sendable, CustomStringConvertible {
    public let raw: String
    private let segments: [String]

    public init(_ pattern: String) {
        self.raw = pattern
        let expanded: String
        if pattern == "~" {
            expanded = PathRedaction.home
        } else if pattern.hasPrefix("~/") {
            expanded = PathRedaction.home + String(pattern.dropFirst(1))
        } else {
            expanded = pattern
        }
        self.segments = expanded
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }

    public var description: String { raw }

    /// The literal prefix before the first wildcard, as an absolute path.
    /// Scanners use this as the directory to start enumerating from.
    public var literalPrefix: String {
        var parts: [String] = []
        for segment in segments {
            if segment.contains("*") { break }
            parts.append(segment)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// True when the pattern contains no wildcards at all.
    public var isLiteral: Bool { !segments.contains { $0.contains("*") } }

    public func matches(_ path: String) -> Bool {
        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        return Self.match(segments[...], components[...])
    }

    // MARK: - Matching

    private static func match(_ segments: ArraySlice<String>, _ components: ArraySlice<String>) -> Bool {
        guard let head = segments.first else { return components.isEmpty }

        if head == "**" {
            let rest = segments.dropFirst()
            // `**` matches zero or more components: try every split point.
            var index = components.startIndex
            while true {
                if match(rest, components[index...]) { return true }
                if index == components.endIndex { return false }
                index = components.index(after: index)
            }
        }

        guard let component = components.first else { return false }
        guard matchSegment(head, component) else { return false }
        return match(segments.dropFirst(), components.dropFirst())
    }

    /// Wildcard match within one component. `*` matches any run of characters
    /// (including none) but never a `/`, since components never contain one.
    static func matchSegment(_ pattern: String, _ text: String) -> Bool {
        if pattern == "*" { return true }
        if !pattern.contains("*") { return pattern == text }

        let p = Array(pattern)
        let t = Array(text)
        var pi = 0, ti = 0
        var starIndex = -1
        var matchIndex = 0

        while ti < t.count {
            if pi < p.count && (p[pi] == t[ti]) {
                pi += 1; ti += 1
            } else if pi < p.count && p[pi] == "*" {
                starIndex = pi
                matchIndex = ti
                pi += 1
            } else if starIndex != -1 {
                pi = starIndex + 1
                matchIndex += 1
                ti = matchIndex
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
