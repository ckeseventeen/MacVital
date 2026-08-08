import Foundation
import Security

/// Facts about the running binary's own code signature.
///
/// Separate from `CodeRequirement` because the two ask different questions:
/// that one builds the XPC requirement strings the app and the helper use to
/// authenticate each other, this one answers "will a TCC grant recorded
/// against this build still match after the next rebuild".
public enum CodeSignature {

    /// Signing information for the running process, or nil when it cannot be
    /// read at all.
    public static func selfInformation() -> [String: Any]? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any]
        else { return nil }
        return dictionary
    }

    public static func teamIdentifier() -> String? {
        selfInformation()?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// True when the binary is ad-hoc signed, so the only thing its designated
    /// requirement can pin to is `cdhash H"…"` — and every recompile changes
    /// that hash, silently invalidating any TCC grant while System Settings
    /// still shows the switch on.
    ///
    /// **This is not the same question as "does it have a team identifier".** A
    /// self-signed certificate carries no team ID yet still yields
    /// `certificate leaf = H"…"`, a requirement that survives rebuilds. Testing
    /// for a team ID reports every self-signed build as unsigned and then warns
    /// the user their grant will expire on every build — wrong for exactly the
    /// builds `make build-selfsigned` exists to produce.
    ///
    /// Unreadable signing information counts as ad-hoc: a bundle with no
    /// signature has no requirement at all, which is worse, not better.
    public static func isAdHoc() -> Bool {
        guard let info = selfInformation() else { return true }
        if let flags = info[kSecCodeInfoFlags as String] as? UInt32 {
            return flags & SecCodeSignatureFlags.adhoc.rawValue != 0
        }
        // Fallback for the case where the flags are missing: no certificate
        // chain means nothing but the cdhash to build a requirement from.
        let certificates = info[kSecCodeInfoCertificates as String] as? [Any]
        return certificates?.isEmpty ?? true
    }
}
