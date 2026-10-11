import SwiftUI
import MacVitalKit

/// The four destinations from the design spec.
enum AppPage: String, CaseIterable, Identifiable {
    case dashboard
    case junk
    case uninstall
    case startup
    case screenshot
    case record
    case annotate
    case whiteboard

    var id: String { rawValue }

    /// Pages whose results depend on Full Disk Access — the only ones that
    /// show the banner asking for it. Screenshots and the whiteboard never
    /// read ~/Library, and nagging there was noise.
    var needsFullDiskAccess: Bool {
        switch self {
        case .dashboard, .junk, .uninstall, .startup: return true
        case .screenshot, .record, .annotate, .whiteboard: return false
        }
    }

    var title: String {
        switch self {
        case .dashboard: return "总览"
        case .junk: return "垃圾清理"
        case .uninstall: return "卸载应用"
        case .startup: return "开机启动项"
        case .screenshot: return "截图"
        case .record: return "录屏与直播"
        case .annotate: return "屏幕画笔"
        case .whiteboard: return "白板"
        }
    }

    var symbolName: String {
        switch self {
        case .dashboard: return "gauge"
        case .junk: return "sparkles"
        case .uninstall: return "app.badge.checkmark"
        case .startup: return "power"
        case .screenshot: return "camera.viewfinder"
        case .record: return "record.circle"
        case .annotate: return "pencil.and.outline"
        case .whiteboard: return "rectangle.on.rectangle"
        }
    }
}

/// The window: a native sidebar and a detail column.
///
/// This was a hand-built `HStack` that had replaced `NavigationSplitView`, for
/// three stated reasons. Each has a native answer, and the hand-built version
/// was paying for not using them:
///
/// * **"It owns its own sidebar chrome."** That is the point of it. The
///   sidebar material, the selection highlight, ⌃⌘S to collapse, arrow-key
///   navigation and VoiceOver's sidebar rotor all come with it. The custom
///   version reimplemented the look and none of the behaviour.
/// * **"Its width is user-draggable."** `navigationSplitViewColumnWidth`
///   bounds it.
/// * **"It has no place for a pinned storage readout."** `safeAreaInset` on
///   the sidebar list — how Music and Mail pin their own footers.
struct AppShell: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ScanViewModel.self) private var model

    /// The page this window was last showing, restored at launch the way
    /// Finder and System Settings come back to where you left them.
    @SceneStorage("selectedPage") private var savedPage: AppPage = .dashboard

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        } detail: {
            detail
        }
        .onAppear { environment.page = savedPage }
        .onChange(of: environment.page) { _, page in savedPage = page }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: selection) {
            row(.dashboard)
            Section("维护") {
                row(.junk)
                row(.uninstall)
                row(.startup)
            }
            Section("捕获") {
                row(.screenshot)
                row(.record)
            }
            Section("创作") {
                row(.annotate)
                row(.whiteboard)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StorageFooter()
        }
    }

    /// `List` selection is optional; the app always has a page. Clicking empty
    /// space in a sidebar deselects, which would otherwise blank the window.
    private var selection: Binding<AppPage?> {
        Binding(
            get: { environment.page },
            set: { if let page = $0 { environment.page = page } }
        )
    }

    private func row(_ page: AppPage) -> some View {
        Label(page.title, systemImage: page.symbolName)
            .badge(badge(for: page).map { Text($0) })
            .tag(page)
    }

    private func badge(for page: AppPage) -> String? {
        switch page {
        case .junk:
            let bytes = model.totalFoundBytes
            return bytes > 0 ? ByteFormat.compact(bytes) : nil
        case .annotate:
            return environment.screenPen.isActive ? "使用中" : nil
        default:
            return nil
        }
    }

    // MARK: - Detail

    private var detail: some View {
        page
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Only where the permission changes what the page can see. The
            // junk page carries an inspector and places the banner in its own
            // content column — see `permissionBannerInset`.
            .permissionBannerInset(
                isEnabled: environment.page.needsFullDiskAccess && environment.page != .junk
            )
            .navigationTitle(environment.page.title)
    }

    @ViewBuilder
    private var page: some View {
        switch environment.page {
        case .dashboard:
            DashboardPage()
        case .junk:
            JunkCleanerPage()
        case .uninstall:
            UninstallPage(environment: environment)
        case .startup:
            StartupPage(environment: environment)
        case .screenshot:
            ScreenshotPage()
        case .record:
            RecordPage()
        case .annotate:
            AnnotatePage()
        case .whiteboard:
            WhiteboardPage(model: environment.whiteboard)
        }
    }
}

/// Free space, pinned under the sidebar list.
private struct StorageFooter: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let disk = environment.diskSpace {
                ProgressView(value: disk.usedFraction)
                    .progressViewStyle(.linear)
                    .tint(disk.usedFraction > 0.9 ? Theme.junk : Theme.accent)
                    .accessibilityLabel("存储空间")
                    .accessibilityValue("已用 \(Int(disk.usedFraction * 100))%")
                Text("已用 \(ByteFormat.string(disk.used)) / \(ByteFormat.string(disk.total))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("正在读取磁盘…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
