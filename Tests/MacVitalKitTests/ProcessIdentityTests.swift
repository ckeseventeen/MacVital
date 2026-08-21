import XCTest
@testable import MacVitalKit

/// The guard that stands between "force quit" and killing an unrelated
/// process.
///
/// A PID is not a stable handle: the verdict naming one is produced during a
/// scan and acted on whenever the user gets round to it, and macOS reissues
/// PIDs once they are freed. These tests use real child processes, because the
/// question is about the kernel's bookkeeping rather than about our own.
final class ProcessIdentityTests: XCTestCase {

    /// Spawns a real process and returns it. Killed in the test's teardown
    /// whatever happens.
    private var spawned: [Process] = []

    override func tearDown() {
        for process in spawned where process.isRunning {
            process.terminate()
        }
        spawned = []
        super.tearDown()
    }

    @discardableResult
    private func spawn(_ launchPath: String, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        spawned.append(process)
        return process
    }

    func testLivePIDReportsItsExecutable() throws {
        let process = try spawn("/bin/sleep", ["30"])
        XCTAssertEqual(
            RunningProcessIndex.currentExecutablePath(for: process.processIdentifier),
            ProtectedPaths.normalize("/bin/sleep")
        )
        XCTAssertTrue(
            RunningProcessIndex.isRunning(pid: process.processIdentifier, executablePath: "/bin/sleep")
        )
    }

    /// The whole point. The PID is alive, but it is not running what was
    /// recorded — which is exactly what a reused PID looks like. Nothing may
    /// be sent to it.
    func testLivePIDRunningSomethingElseIsNotAMatch() throws {
        let process = try spawn("/bin/sleep", ["30"])
        XCTAssertFalse(
            RunningProcessIndex.isRunning(pid: process.processIdentifier, executablePath: "/usr/bin/true"),
            "a PID running a different executable must never be treated as the recorded process"
        )
    }

    func testDeadPIDIsNotRunning() throws {
        let process = try spawn("/bin/sleep", ["30"])
        let pid = process.processIdentifier
        process.terminate()
        process.waitUntilExit()

        XCTAssertFalse(RunningProcessIndex.isRunning(pid: pid, executablePath: "/bin/sleep"))
        XCTAssertNil(RunningProcessIndex.currentExecutablePath(for: pid))
    }

    /// `/var` and `/private/var` are the same place. A path that fails to match
    /// only because of firmlink spelling would report a live process as gone,
    /// and the terminator would quietly decline to stop it.
    func testComparisonIsNormalised() throws {
        let process = try spawn("/bin/sleep", ["30"])
        let recorded = RunningProcessIndex.currentExecutablePath(for: process.processIdentifier)
        XCTAssertEqual(recorded, ProtectedPaths.normalize(try XCTUnwrap(recorded)))
    }

    func testImplausiblePIDIsNotRunning() {
        XCTAssertFalse(RunningProcessIndex.isRunning(pid: 999_999, executablePath: "/bin/sleep"))
    }
}
