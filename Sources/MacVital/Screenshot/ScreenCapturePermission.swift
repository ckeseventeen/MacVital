import AppKit
import ScreenCaptureKit

/// Screen Recording (`kTCCServiceScreenCapture`), in one place.
///
/// Three capture paths depend on it — `screencapture`, the recorder and the
/// LAN broadcast — and until now only the two ScreenCaptureKit ones knew it
/// existed, each carrying its own copy of the same sentence.
///
/// Worth knowing about this permission specifically: **macOS never prompts for
/// it.** TCC logs `Service kTCCServiceScreenCapture does not allow prompting;
/// returning denied` and posts a notification instead, so an app that says
/// nothing leaves the user with no in-app explanation at all.
enum ScreenCapturePermission {

    /// Asking for shareable content *is* the check — it throws when the grant
    /// is missing — and the first call is also what gets the app listed in
    /// System Settings in the first place. There is no preflight-only API.
    static func isGranted() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    /// `SCStream` reports a missing grant as a bare -3801 rather than anything
    /// nameable; recognising it is the difference between an actionable
    /// message and a hex code.
    static func isDenial(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && nsError.code == -3801
    }

    /// The second paragraph is not padding. A grant is keyed to the app's
    /// designated requirement, and macOS resolves the bundle identifier to
    /// *some* copy of the app — if a second `MacVital.app` claiming the same
    /// identifier is lying around (a build directory is the usual culprit),
    /// the requirement check fails against that one and the switch in System
    /// Settings has no effect no matter how many times it is toggled.
    static let message = """
        没有「屏幕录制」权限。请到「系统设置 → 隐私与安全性 → 屏幕录制」中勾选 MacVital，然后重启 App。

        如果列表里已经有 MacVital 却依然不行，多半是系统匹配到了另一份声明同样 bundle id 的 MacVital.app\
        （构建目录里遗留的那份最常见）：先删掉多余的副本，再用「−」移除条目并重新添加 /Applications/MacVital.app。
        """

    static func openSettings() {
        // macOS 13 renamed the privacy pane. The pre-Ventura identifier still
        // opens System Settings but lands on the wrong page, which reads to the
        // user as the button being broken — so try the modern anchor first.
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        ]
        for string in candidates {
            guard let url = URL(string: string) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
    }
}
