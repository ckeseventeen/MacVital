import Foundation

/// What an HTTP request line to the screen broadcast is asking for.
///
/// This is the only access control in the app. The broadcast server binds every
/// interface, so on a conference-room or café network the URL *is* the
/// permission — the same model a share link uses. Getting the comparison wrong
/// hands a stranger a live view of the screen, which puts it well inside what
/// the kit is for, and is why it lives here rather than in the view layer: the
/// app target has no test bundle by design (building one produces a second,
/// unsigned `MacVital.app`, and macOS may resolve the bundle identifier to
/// *that* when checking a TCC requirement).
public enum BroadcastRoute: Equatable, Sendable {
    /// The viewer page.
    case page
    /// The MJPEG stream itself.
    case stream
    /// Anything else, including a wrong or absent token.
    case reject

    /// `GET /<token>` and `GET /<token>/stream`, and nothing else.
    ///
    /// A request carrying the wrong token gets the same answer as one arriving
    /// after the broadcast stopped, so probing cannot tell the two apart.
    public static func parse(request: String, token: String) -> BroadcastRoute {
        // An empty token means no broadcast is running. Comparing against it
        // would make every request match.
        guard !token.isEmpty else { return .reject }
        guard let line = request.split(separator: "\r\n", maxSplits: 1).first else { return .reject }

        let fields = line.split(separator: " ")
        guard fields.count >= 2, fields[0] == "GET" else { return .reject }

        var path = String(fields[1])
        if let query = path.firstIndex(of: "?") { path = String(path[path.startIndex..<query]) }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }

        // Exact matches only. No normalisation, no traversal handling, no
        // case folding — anything that is not one of these two strings is
        // simply not a route this server has.
        if path == "/\(token)" { return .page }
        if path == "/\(token)/stream" { return .stream }
        return .reject
    }

    /// Eight characters from a 31-letter alphabet — about 40 bits.
    ///
    /// Sized against the actual threat and the actual use. The point of the
    /// feature is that someone reads a URL off a projector and types it on
    /// their phone, so a 32-character hex string would defeat the feature in
    /// order to defend it. 40 bits is far past what an attacker can walk
    /// through against a broadcast that lasts an hour and whose token changes
    /// every time it starts. `i`, `l`, `o` and `u` are left out: they are the
    /// ones people mistype off a screen.
    public static let tokenAlphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")

    public static func makeToken() -> String {
        String((0..<8).map { _ in tokenAlphabet.randomElement()! })
    }
}
