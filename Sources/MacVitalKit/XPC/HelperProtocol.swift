import Foundation
import Security

public enum HelperConstants {
    /// Mach service name. Must match `MachServices` in the launchd plist.
    public static let machServiceName = "com.macvital.helper"
    /// Filename of the plist in Contents/Library/LaunchDaemons.
    public static let daemonPlistName = "com.macvital.helper.plist"
    public static let appBundleIdentifier = "com.macvital.MacVital"
    public static let helperBundleIdentifier = "com.macvital.helper"
    public static let version = "1.0.0"
}

/// The privileged surface. Kept as small as it can possibly be: the main
/// process never runs as root, and the helper exposes four verbs, all of which
/// re-validate their arguments against the same rule engine the app used.
///
/// The helper trusts nothing the client sends. A compromised or spoofed client
/// gets the same answer as a buggy one — the guards run on this side too.
@objc public protocol MacVitalHelperProtocol {
    func helperVersion(withReply reply: @escaping (String) -> Void)

    /// Move root-owned paths into the quarantine store.
    /// Reply: (path -> stored path) for successes, (path -> message) for failures.
    func moveToQuarantine(
        paths: [String],
        quarantineRoot: String,
        withReply reply: @escaping ([String: String], [String: String]) -> Void
    )

    /// Put one quarantined item back where it came from.
    func restore(
        storedPath: String,
        originalPath: String,
        quarantineRoot: String,
        withReply reply: @escaping (String?) -> Void
    )

    /// Hard delete, only ever inside the quarantine root.
    func purge(
        storedPaths: [String],
        quarantineRoot: String,
        withReply reply: @escaping ([String: String]) -> Void
    )

    /// Unregister and remove itself.
    func uninstall(withReply reply: @escaping (Bool) -> Void)
}

/// Code-signing requirement strings used by both sides of the connection.
///
/// Built from the running binary's own team identifier so the project works
/// without a hardcoded team ID — and so a build signed with a different
/// identity cannot talk to a helper installed by this one.
public enum CodeRequirement {
    public static func teamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any]
        else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// What the helper demands of anything connecting to it.
    public static func forClient() -> String? {
        guard let team = teamIdentifier() else { return nil }
        return requirement(identifier: HelperConstants.appBundleIdentifier, team: team)
    }

    /// What the app demands of the helper it connects to.
    public static func forHelper() -> String? {
        guard let team = teamIdentifier() else { return nil }
        return requirement(identifier: HelperConstants.helperBundleIdentifier, team: team)
    }

    private static func requirement(identifier: String, team: String) -> String {
        // Anchored to Apple's root, pinned to our team, pinned to the exact
        // bundle identifier, and requiring a modern signature version.
        """
        identifier "\(identifier)" \
        and anchor apple generic \
        and certificate leaf[subject.OU] = "\(team)" \
        and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
        and certificate leaf[field.1.2.840.113635.100.6.1.13] exists
        """
    }
}
