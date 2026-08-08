import Foundation
import AppKit
import MacVitalKit

/// Without Full Disk Access this app sees almost nothing: `~/Library/Caches`,
/// `~/Library/Containers` and `~/Library/Application Support` are all TCC
/// protected. So the permission state is a first-class thing the UI shows,
/// not an error surfaced when a scan comes back empty.
@MainActor
final class PermissionsCoordinator: ObservableObject {
    enum State: Equatable {
        case granted
        case denied
        /// Every probe was absent. Not the same as denied, and the UI must not
        /// claim the permission is missing when it does not actually know.
        case unknown
    }

    @Published private(set) var fullDiskAccess: State = .unknown
    /// Set once the user has been sent to System Settings.
    @Published private(set) var didOpenSettings = false
    /// When `refresh()` last ran. Shown in the banner purely so that pressing
    /// "re-check" visibly does *something* — the state itself usually cannot
    /// change within one process lifetime (see `mustRelaunchToTakeEffect`).
    @Published private(set) var lastCheckedAt: Date?

    /// macOS binds Full Disk Access at **process launch**. Toggling it in
    /// System Settings does not reach a process that is already running —
    /// which is why System Settings itself offers to quit and reopen the app.
    ///
    /// So re-probing from the running app can confirm a grant that was already
    /// in place, but it can never observe one the user just made. The banner
    /// has to say so, otherwise "re-check" looks broken when it is in fact
    /// reporting the truth.
    let mustRelaunchToTakeEffect = true

    /// True when the running binary is ad-hoc signed, i.e. what `make build`
    /// produces without a certificate.
    ///
    /// This matters more than it looks. TCC keys a grant on the app's
    /// designated requirement, and an ad-hoc signature has no certificate to
    /// pin one to — so the requirement is the binary's cdhash. **Every
    /// recompile changes the cdhash**, and the old grant stops applying while
    /// the toggle in System Settings still shows the app enabled. The user
    /// sees a switch that is on and an app that says it has no access, and
    /// both are correct.
    ///
    /// This used to test `CodeRequirement.teamIdentifier() == nil`, which is a
    /// different question with a different answer: a self-signed certificate
    /// carries no team identifier yet still yields a stable
    /// `certificate leaf = H"…"` requirement. That test reported every
    /// `make build-selfsigned` build as unsigned and then told the user to
    /// re-add the app after every build — precisely the advice that signing
    /// with a certificate exists to make unnecessary.
    let grantsExpireOnRebuild = CodeSignature.isAdHoc()

    /// Screen Recording, which the capture pages need.
    ///
    /// Unlike Full Disk Access it is not bound at launch, so it can be
    /// re-probed live — but macOS never *prompts* for it either. TCC refuses
    /// to show a dialog for this service and posts a notification instead, so
    /// an app that does not report the state itself leaves the user with
    /// nothing to act on.
    @Published private(set) var screenRecording: State = .unknown

    /// TCC-protected files, tried in order. Several, because none of them is
    /// guaranteed to exist: the per-user TCC database that older code probes
    /// is **gone on macOS 26+**, Safari's bookmarks are missing if Safari has
    /// never run, and Messages' store is absent on a fresh account. Probing a
    /// path that does not exist yields no information at all — which is how
    /// the previous implementation ended up reporting "not granted" on a
    /// machine where it simply could not tell.
    private static var probePaths: [String] {
        let home = NSHomeDirectory()
        return [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            "\(home)/Library/Application Support/com.apple.TCC/TCC.db",
            "\(home)/Library/Safari/Bookmarks.plist",
            "\(home)/Library/Messages/chat.db",
            "\(home)/Library/Mail",
        ]
    }

    private enum ProbeResult {
        case readable
        case refused
        case absent
    }

    /// The only reliable test is to actually open the file.
    ///
    /// `FileManager.isReadableFile` calls `access(2)`, which answers a POSIX
    /// permission question. TCC is not POSIX permissions — it denies at
    /// `open(2)` with EPERM — so `access` can happily report a file as
    /// readable that the process cannot open. That mismatch was the root of
    /// the inconsistent banner.
    private static func probe(_ path: String) -> ProbeResult {
        guard FileManager.default.fileExists(atPath: path) else { return .absent }

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            // Opening a directory succeeds regardless; listing it is the part
            // TCC gates.
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: path)
                return .readable
            } catch {
                let code = (error as NSError).code
                return (code == NSFileReadNoPermissionError) ? .refused : .absent
            }
        }

        let descriptor = open(path, O_RDONLY)
        if descriptor >= 0 {
            close(descriptor)
            return .readable
        }
        return (errno == EPERM || errno == EACCES) ? .refused : .absent
    }

    func refresh() {
        lastCheckedAt = Date()
        var sawRefusal = false
        for path in Self.probePaths {
            switch Self.probe(path) {
            case .readable:
                // One success is proof: these paths are unreadable without the
                // permission, so reading any of them means we have it.
                fullDiskAccess = .granted
                Log.app.debug("full disk access granted (probe \(path, privacy: .public))")
                return
            case .refused:
                sawRefusal = true
            case .absent:
                continue
            }
        }
        fullDiskAccess = sawRefusal ? .denied : .unknown
        Log.app.notice("full disk access \(sawRefusal ? "denied" : "undetermined", privacy: .public)")
    }

    /// Deliberately not folded into `refresh()`: this one is asynchronous, and
    /// probing it while denied makes macOS post its "open System Settings"
    /// notification. That is the right thing when the user has just asked
    /// about permissions, and noise on every app activation.
    func refreshScreenRecording() async {
        let granted = await ScreenCapturePermission.isGranted()
        screenRecording = granted ? .granted : .denied
        Log.app.notice("screen recording \(granted ? "granted" : "denied", privacy: .public)")
    }

    // MARK: - Actions

    func openSystemSettings() {
        didOpenSettings = true
        // macOS 13 renamed the privacy pane. The pre-Ventura identifier still
        // opens System Settings but lands on the wrong page, which reads to the
        // user as the button being broken — so try the modern anchor first and
        // only fall back if it is refused.
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        ]
        for string in candidates {
            guard let url = URL(string: string) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
    }

    func openScreenRecordingSettings() {
        didOpenSettings = true
        ScreenCapturePermission.openSettings()
    }

    /// Full Disk Access is evaluated when a process launches; a running process
    /// does not pick it up. Relaunching is genuinely required, not a nicety.
    func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            guard error == nil else { return }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
