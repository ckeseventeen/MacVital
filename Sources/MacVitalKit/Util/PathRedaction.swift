import Foundation

/// Paths are the most identifying thing this app touches. Anything that could
/// leave the machine (cloud advisor, logs, crash reports, exported reports)
/// goes through here first.
public enum PathRedaction {
    public static let home = NSHomeDirectory()
    public static let userName = NSUserName()

    /// `/Users/alice/Library/Caches/x` -> `~/Library/Caches/x`
    public static func abbreviate(_ path: String) -> String {
        guard path.hasPrefix(home) else { return path }
        let suffix = String(path.dropFirst(home.count))
        return suffix.isEmpty ? "~" : "~" + suffix
    }

    /// Stronger than `abbreviate`: also scrubs the short username wherever it
    /// appears in the remainder of the path, and any `/Users/<other>` prefixes.
    public static func redact(_ path: String) -> String {
        var result = abbreviate(path)
        if !userName.isEmpty {
            result = result.replacingOccurrences(of: userName, with: "<user>")
        }
        result = redactOtherUsers(in: result)
        return result
    }

    private static func redactOtherUsers(in path: String) -> String {
        guard path.hasPrefix("/Users/") else { return path }
        var components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // components == ["", "Users", "<name>", ...]
        if components.count > 2 {
            components[2] = "<user>"
        }
        return components.joined(separator: "/")
    }

    /// Filenames sometimes embed the account name or an email. Used before
    /// sending directory listings to a remote model.
    public static func redactName(_ name: String) -> String {
        guard !userName.isEmpty else { return name }
        return name.replacingOccurrences(of: userName, with: "<user>")
    }
}
