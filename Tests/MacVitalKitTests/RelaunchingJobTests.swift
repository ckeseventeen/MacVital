import XCTest
@testable import MacVitalKit

/// `KeepAlive` means launchd owns the process's lifetime: kill it and it is
/// back, with a new PID, in about a second.
///
/// Three daemons on the machine this was written against carry it, and two of
/// them belong to apps the residue scanner offers to remove — so 强制结束 on
/// one of those is a button that visibly does nothing. Same shape of failure as
/// offering a privileged removal on a build whose helper can never connect,
/// which this codebase already refuses to do.
final class RelaunchingJobTests: XCTestCase {

    /// The plain form.
    func testBooleanKeepAlive() {
        XCTAssertTrue(LaunchItemAttribution.keepsAlive(true))
        XCTAssertFalse(LaunchItemAttribution.keepsAlive(false))
    }

    /// A dictionary means "keep alive under these circumstances", which is
    /// still keep-alive — one of the daemons found in the wild uses this form,
    /// and reading it as "no" would have missed it.
    func testDictionaryKeepAliveCountsAsKeepAlive() {
        XCTAssertTrue(LaunchItemAttribution.keepsAlive(["SuccessfulExit": false]))
        XCTAssertTrue(LaunchItemAttribution.keepsAlive([String: Any]()))
    }

    /// Absent or nonsense is not keep-alive. `RunAtLoad` on its own only starts
    /// the job at login; it does not resurrect it.
    func testMissingOrUnrelatedValueIsNotKeepAlive() {
        XCTAssertFalse(LaunchItemAttribution.keepsAlive(nil))
        XCTAssertFalse(LaunchItemAttribution.keepsAlive("yes"))
        XCTAssertFalse(LaunchItemAttribution.keepsAlive(1))
    }

    /// The lookup is by program path, and a path nothing launches must come
    /// back nil — otherwise every kill would carry a warning that does not
    /// apply, which is how warnings stop being read.
    func testUnlaunchedProgramHasNoRelaunchingJob() {
        LaunchItemAttribution.invalidate()
        XCTAssertNil(
            LaunchItemAttribution.relaunchingJob(forProgram: "/nonexistent/\(UUID().uuidString)/tool")
        )
    }
}
