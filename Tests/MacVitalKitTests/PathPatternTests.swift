import XCTest
@testable import MacVitalKit

final class PathPatternTests: XCTestCase {

    func testLiteralMatch() {
        let pattern = PathPattern("/Library/LaunchDaemons/foo.plist")
        XCTAssertTrue(pattern.matches("/Library/LaunchDaemons/foo.plist"))
        XCTAssertFalse(pattern.matches("/Library/LaunchDaemons/foo.plist.bak"))
        XCTAssertFalse(pattern.matches("/Library/LaunchDaemons"))
    }

    func testSingleStarMatchesOneComponentOnly() {
        let pattern = PathPattern("/Library/LaunchDaemons/*.plist")
        XCTAssertTrue(pattern.matches("/Library/LaunchDaemons/com.acme.plist"))
        // Must not reach into a subdirectory.
        XCTAssertFalse(pattern.matches("/Library/LaunchDaemons/nested/com.acme.plist"))
        XCTAssertFalse(pattern.matches("/Library/LaunchDaemons/com.acme.txt"))
    }

    func testGlobstarMatchesZeroOrMoreComponents() {
        let pattern = PathPattern("/a/**/node_modules")
        XCTAssertTrue(pattern.matches("/a/node_modules"))
        XCTAssertTrue(pattern.matches("/a/b/node_modules"))
        XCTAssertTrue(pattern.matches("/a/b/c/d/node_modules"))
        XCTAssertFalse(pattern.matches("/a/b/node_modules/lodash"))
    }

    func testLeadingGlobstar() {
        let pattern = PathPattern("**/node_modules")
        XCTAssertTrue(pattern.matches("/Users/x/proj/node_modules"))
        XCTAssertTrue(pattern.matches("/node_modules"))
        XCTAssertFalse(pattern.matches("/Users/x/node_modules_old"))
    }

    func testTildeExpansion() {
        let pattern = PathPattern("~/Library/Caches/*")
        XCTAssertTrue(pattern.matches("\(PathRedaction.home)/Library/Caches/com.acme"))
        XCTAssertFalse(pattern.matches("/Users/somebodyelse/Library/Caches/com.acme"))
    }

    func testLiteralPrefixStopsAtFirstWildcard() {
        XCTAssertEqual(PathPattern("/a/b/*/d").literalPrefix, "/a/b")
        XCTAssertEqual(PathPattern("/a/b/c").literalPrefix, "/a/b/c")
        XCTAssertEqual(PathPattern("/**").literalPrefix, "/")
    }

    /// The wildcard must never cross a component boundary — this is what
    /// keeps `~/Library/Caches/*` from authorising a nested path.
    func testSegmentMatcherDoesNotSpanSlashes() {
        XCTAssertTrue(PathPattern.matchSegment("com.*.plist", "com.acme.plist"))
        XCTAssertTrue(PathPattern.matchSegment("*", "anything"))
        XCTAssertTrue(PathPattern.matchSegment("*.savedState", "com.acme.savedState"))
        XCTAssertFalse(PathPattern.matchSegment("*.plist", "com.acme.plist.bak"))
        XCTAssertFalse(PathPattern.matchSegment("abc", "abcd"))
    }

    func testEmptyAndRootEdgeCases() {
        XCTAssertTrue(PathPattern("/**").matches("/anything/at/all"))
        XCTAssertFalse(PathPattern("/a/b").matches("/a"))
        XCTAssertFalse(PathPattern("/a").matches("/a/b"))
    }
}
