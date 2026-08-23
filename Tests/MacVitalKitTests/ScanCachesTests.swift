import XCTest
@testable import MacVitalKit

/// Four caches, reset together.
///
/// They were dropped in `ScanEngine.scan` and nowhere else, which left the two
/// screens that build their own engine — uninstall and startup items — reading
/// whatever the last sweep had memoised, for the life of the process. The
/// visible version: disable a launch item, watch the list reload, and the row
/// still reports that launchd will restart it.
final class ScanCachesTests: XCTestCase {

    /// A memo that answers differently after being dropped is worse than no
    /// memo at all, so the same question has to survive the round trip.
    func testAnswersSurviveInvalidation() {
        let before = SystemDomainIndex.isSystemDomain("org.cups.printers")
        ScanCaches.invalidate()
        let afterFirst = SystemDomainIndex.isSystemDomain("org.cups.printers")
        ScanCaches.invalidate()
        let afterSecond = SystemDomainIndex.isSystemDomain("org.cups.printers")

        XCTAssertTrue(before)
        XCTAssertEqual(before, afterFirst)
        XCTAssertEqual(afterFirst, afterSecond)
    }

    /// Invalidating with nothing built yet must not be a special case — the
    /// startup screen calls it on its very first reload.
    func testInvalidatingBeforeAnythingIsBuiltIsSafe() {
        ScanCaches.invalidate()
        ScanCaches.invalidate()
        XCTAssertFalse(SystemDomainIndex.isSystemDomain("com.docker.vmnetd"))
        XCTAssertNil(LaunchItemAttribution.relaunchingJob(forProgram: "/nonexistent/\(UUID().uuidString)"))
    }

    /// The scanners run concurrently in a task group, so a reset landing while
    /// another one is rebuilding must not trap.
    func testConcurrentInvalidationAndQueryDoNotTrap() async {
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    if index.isMultiple(of: 3) {
                        ScanCaches.invalidate()
                    } else {
                        _ = SystemDomainIndex.isSystemDomain("org.apache.httpd")
                        _ = PackageOwnership.isSystemProvided("/Library/Preferences")
                    }
                }
            }
        }
        XCTAssertTrue(SystemDomainIndex.isSystemDomain("org.apache.httpd"))
    }
}
