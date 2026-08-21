import XCTest
@testable import MacVitalKit

/// The screen broadcast serves to every interface, so the URL is the
/// permission. This is the comparison that decides whether a stranger on the
/// same network gets a live view of the screen.
final class BroadcastRouteTests: XCTestCase {

    private let token = "a1b2c3d4"

    private func route(_ line: String, token: String? = nil) -> BroadcastRoute {
        BroadcastRoute.parse(request: "\(line)\r\nHost: x\r\n\r\n", token: token ?? self.token)
    }

    // MARK: - What must work

    func testTokenPathServesThePage() {
        XCTAssertEqual(route("GET /a1b2c3d4 HTTP/1.1"), .page)
    }

    func testStreamPathServesTheStream() {
        XCTAssertEqual(route("GET /a1b2c3d4/stream HTTP/1.1"), .stream)
    }

    /// Browsers add and drop trailing slashes freely.
    func testTrailingSlashIsIgnored() {
        XCTAssertEqual(route("GET /a1b2c3d4/ HTTP/1.1"), .page)
        XCTAssertEqual(route("GET /a1b2c3d4/stream/ HTTP/1.1"), .stream)
    }

    /// Cache-busting query strings are common and carry no meaning here.
    func testQueryStringIsIgnored() {
        XCTAssertEqual(route("GET /a1b2c3d4?t=1699 HTTP/1.1"), .page)
        XCTAssertEqual(route("GET /a1b2c3d4/stream?t=1699 HTTP/1.1"), .stream)
    }

    // MARK: - What must not

    func testWrongTokenIsRejected() {
        XCTAssertEqual(route("GET /deadbeef HTTP/1.1"), .reject)
        XCTAssertEqual(route("GET /deadbeef/stream HTTP/1.1"), .reject)
    }

    /// A stopped broadcast has no token. Comparing against an empty one would
    /// make `/` — and everything else — match.
    func testEmptyTokenRejectsEverything() {
        XCTAssertEqual(route("GET / HTTP/1.1", token: ""), .reject)
        XCTAssertEqual(route("GET /stream HTTP/1.1", token: ""), .reject)
        XCTAssertEqual(route("GET /a1b2c3d4 HTTP/1.1", token: ""), .reject)
    }

    /// The old behaviour: anything that was not `/stream` served the page, so
    /// a bare `GET /` showed the screen to whoever asked.
    func testBareRootIsRejected() {
        XCTAssertEqual(route("GET / HTTP/1.1"), .reject)
        XCTAssertEqual(route("GET /stream HTTP/1.1"), .reject)
    }

    /// Exact match, so a token that only differs in case is a different token.
    func testTokenComparisonIsCaseSensitive() {
        XCTAssertEqual(route("GET /A1B2C3D4 HTTP/1.1"), .reject)
    }

    /// No path normalisation, so traversal spellings simply are not routes.
    func testTraversalSpellingsAreNotRoutes() {
        XCTAssertEqual(route("GET /a1b2c3d4/../a1b2c3d4 HTTP/1.1"), .reject)
        XCTAssertEqual(route("GET //a1b2c3d4 HTTP/1.1"), .reject)
        XCTAssertEqual(route("GET /a1b2c3d4/stream/../stream HTTP/1.1"), .reject)
    }

    /// A prefix of the token is not the token, and neither is the token plus
    /// something.
    func testPartialAndExtendedTokensAreRejected() {
        XCTAssertEqual(route("GET /a1b2 HTTP/1.1"), .reject)
        XCTAssertEqual(route("GET /a1b2c3d4x HTTP/1.1"), .reject)
        XCTAssertEqual(route("GET /a1b2c3d4/other HTTP/1.1"), .reject)
    }

    func testOnlyGETIsRouted() {
        XCTAssertEqual(route("POST /a1b2c3d4 HTTP/1.1"), .reject)
        XCTAssertEqual(route("HEAD /a1b2c3d4 HTTP/1.1"), .reject)
    }

    func testMalformedRequestsAreRejected() {
        XCTAssertEqual(BroadcastRoute.parse(request: "", token: token), .reject)
        XCTAssertEqual(route("GET"), .reject)
        XCTAssertEqual(route("nonsense"), .reject)
    }

    // MARK: - Tokens

    /// Long enough that walking the space is not a strategy, short enough to
    /// type off a projector — and drawn from an alphabet without the
    /// characters people misread.
    func testTokensAreTypeableAndUnguessable() {
        let tokens = (0..<200).map { _ in BroadcastRoute.makeToken() }
        for token in tokens {
            XCTAssertEqual(token.count, 8)
            XCTAssertTrue(token.allSatisfy { BroadcastRoute.tokenAlphabet.contains($0) }, token)
        }
        XCTAssertFalse(BroadcastRoute.tokenAlphabet.contains(where: { "ilou".contains($0) }))
        XCTAssertGreaterThan(Set(tokens).count, 190, "tokens must not repeat in any practical sense")
    }
}
