import AppKit
import Darwin
import Foundation
import MacVitalKit

/// Closes whatever is holding a file open, so "先退出它" is a button rather than
/// an instruction.
///
/// `.inUse` is the only deny reason the user can clear, and until now the app
/// said so and left them to it — find the app, quit it, come back, rescan. For
/// an app that ignores a quit request (a modal sheet, a hung process) there was
/// no way forward at all short of Activity Monitor.
///
/// Two escalating steps, never one:
///
///   * **Quit** is `NSRunningApplication.terminate()` / `SIGTERM`. The program
///     runs its own quit path, flushes what it was writing and gets to ask
///     about unsaved work. This is what should happen, and usually does.
///   * **Force quit** is `forceTerminate()` / `SIGKILL`. The program gets no
///     say and no chance to save. It is offered only after a graceful quit has
///     visibly failed, and it asks first.
///
/// Killing a process to delete its files is a trade the user has to make
/// knowingly — unsaved work is exactly the kind of data this app exists not to
/// lose — so `forceQuit` is never reached without an explicit confirmation in
/// the UI above it.
@MainActor
enum ProcessTerminator {

    /// Something the app can offer to close.
    enum Target: Equatable {
        /// A GUI application, addressable through its bundle identifier. All
        /// running instances are closed together.
        case application(bundleIdentifier: String, name: String)
        /// A bare process — a daemon, a helper, a compiler. Addressed by PID,
        /// and carrying what that PID was running when it was recorded so the
        /// number can be re-confirmed before anything is sent to it.
        case process(pid: pid_t, executablePath: String, name: String)

        var name: String {
            switch self {
            case .application(_, let name), .process(_, _, let name): return name
            }
        }

        /// Whether the target still exists. A quit that already happened is a
        /// success, not a failure.
        ///
        /// Isolated explicitly: a nested type does not inherit the enclosing
        /// declaration's actor isolation, and `NSRunningApplication` lookups
        /// are main-actor work.
        @MainActor
        var isRunning: Bool {
            switch self {
            case .application(let identifier, _):
                return !ProcessTerminator.instances(of: identifier).isEmpty
            case .process(let pid, let executablePath, _):
                // Existence is not enough: a recycled PID exists too. The
                // question is whether *this* process is still running.
                return ProcessTerminator.isStillTheRecordedProcess(pid, executablePath)
            }
        }
    }

    enum Outcome: Equatable {
        case closed
        /// It is still running. The caller decides whether to escalate.
        case stillRunning
        /// We are not allowed to touch it — a root-owned daemon, most often.
        /// The main process never runs as root, and that is deliberate.
        case notPermitted
    }

    // MARK: - Reading a decision

    /// The thing to offer closing for a refused item, if there is one.
    ///
    /// Prefers the bundle identifier: quitting an app through
    /// `NSRunningApplication` runs its real quit path, while signalling one of
    /// its PIDs does not.
    static func target(for decision: RuleDecision) -> Target? {
        guard decision.denyReason == .inUse, let blocker = decision.blockedBy else { return nil }

        if let identifier = blocker.bundleIdentifier, !instances(of: identifier).isEmpty {
            return .application(bundleIdentifier: identifier, name: blocker.name)
        }
        // A PID with no recorded executable cannot be confirmed later, and an
        // unconfirmable PID is not something to send SIGKILL to. Offering
        // nothing is the right answer — the row keeps its explanation.
        if let pid = blocker.pid, let executable = blocker.executablePath,
           pid > 1, pid != getpid() {
            return .process(pid: pid, executablePath: executable, name: blocker.name)
        }
        return nil
    }

    /// The launchd job that would bring this target straight back, if any.
    ///
    /// Worth asking *before* offering to kill anything: a `KeepAlive` job is
    /// owned by launchd, so the process reappears with a new PID about a second
    /// later. The button works and the outcome is unchanged, which is the most
    /// confusing failure an interface can produce.
    static func relaunchingJob(for target: Target) -> LaunchItemAttribution.RelaunchingJob? {
        switch target {
        case .process(_, let executablePath, _):
            return LaunchItemAttribution.relaunchingJob(forProgram: executablePath)
        case .application(let identifier, _):
            // An app is not usually launchd-managed, but a background agent
            // with a bundle identifier is — and that is exactly the shape the
            // uninstaller runs into.
            guard let executable = instances(of: identifier)
                .compactMap({ $0.executableURL?.path })
                .first
            else { return nil }
            return LaunchItemAttribution.relaunchingJob(forProgram: executable)
        }
    }

    // MARK: - Closing

    /// Ask nicely. The app gets to prompt about unsaved work, so this can take
    /// as long as the user does — hence polling rather than a fixed wait.
    static func quit(_ target: Target) async -> Outcome {
        switch target {
        case .application(let identifier, _):
            let running = instances(of: identifier)
            guard !running.isEmpty else { return .closed }
            for application in running { application.terminate() }
            return await settle(target)

        case .process(let pid, let executablePath, _):
            guard isSignallable(pid) else { return .notPermitted }
            guard isStillTheRecordedProcess(pid, executablePath) else { return .closed }
            guard kill(pid, SIGTERM) == 0 else {
                return errno == EPERM ? .notPermitted : .closed
            }
            return await settle(target)
        }
    }

    /// Take it away. No save prompt, no cleanup — only offered after `quit`
    /// has failed, and only with the user's explicit agreement.
    static func forceQuit(_ target: Target) async -> Outcome {
        switch target {
        case .application(let identifier, _):
            let running = instances(of: identifier)
            guard !running.isEmpty else { return .closed }
            for application in running { application.forceTerminate() }
            return await settle(target)

        case .process(let pid, let executablePath, _):
            guard isSignallable(pid) else { return .notPermitted }
            // Re-checked immediately before SIGKILL, not just before SIGTERM:
            // the graceful attempt and its three-second wait sit between the
            // two, which is plenty of time for the PID to be freed and reused.
            guard isStillTheRecordedProcess(pid, executablePath) else { return .closed }
            guard kill(pid, SIGKILL) == 0 else {
                return errno == EPERM ? .notPermitted : .closed
            }
            return await settle(target)
        }
    }

    // MARK: - Guards

    /// Refuses the PIDs that must never be signalled, whatever asked.
    ///
    /// `launchd` is PID 1 and taking it down panics the machine; signalling
    /// ourselves would kill the app mid-cleanup, with a quarantine move
    /// possibly half-done. Everything else the kernel arbitrates: this process
    /// is not root, so a signal to a root-owned daemon fails with `EPERM` and
    /// is reported as `.notPermitted` rather than pretended away.
    private static func isSignallable(_ pid: pid_t) -> Bool {
        pid > 1 && pid != getpid()
    }

    /// Whether `pid` is still running the executable it was recorded with.
    ///
    /// The verdict that produced this target was made during a scan; the user
    /// may act on it minutes later. macOS hands PIDs out again after they are
    /// freed, so by then the number can belong to something else — and the
    /// difference between "the compiler you wanted to stop" and "whatever
    /// happened to start next" is invisible from the PID alone.
    ///
    /// A mismatch is reported to the caller as `.closed`, because it is: the
    /// process that was holding the file is gone. What must not happen is
    /// signalling its replacement.
    /// Delegates to the kit, which is where it can be tested — this target has
    /// no test bundle by design (see `RunningProcessIndex.isRunning`).
    private static func isStillTheRecordedProcess(_ pid: pid_t, _ executablePath: String) -> Bool {
        RunningProcessIndex.isRunning(pid: pid, executablePath: executablePath)
    }

    private static func instances(of bundleIdentifier: String) -> [NSRunningApplication] {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated }
    }

    /// Waits for the target to actually go away.
    ///
    /// Bounded at three seconds: a graceful quit that has not landed by then is
    /// waiting on the user (an unsaved-changes sheet), and the honest answer is
    /// "still running" so the UI can say so and offer the next step.
    private static func settle(_ target: Target) async -> Outcome {
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(150))
            if !target.isRunning { return .closed }
        }
        return target.isRunning ? .stillRunning : .closed
    }
}
