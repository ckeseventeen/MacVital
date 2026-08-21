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
        case .dashboard: return "house"
        case .junk: return "trash"
        case .uninstall: return "square.grid.2x2"
        case .startup: return "power"
        case .screenshot: return "camera.viewfinder"
        case .record: return "record.circle"
        case .annotate: return "pencil.tip"
        case .whiteboard: return "square.on.square"
        }
    }
}

/// Fixed-width sidebar plus content pane, replacing `NavigationSplitView`.
///
/// The split view could not produce the spec's layout: it owns its own sidebar
/// chrome, its width is user-draggable, and it has no place for a pinned
/// storage readout at the bottom. This is a plain `HStack`, which is all the
/// design actually needs.
struct AppShell: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var model: ScanViewModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(Theme.separator)
                .frame(width: 1)
            content
        }
        .background(Theme.surface)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            logo
            nav
            Spacer(minLength: 12)
            storage
        }
        .frame(width: Theme.Metric.sidebarWidth)
        .glassChrome()
    }

    private var logo: some View {
        HStack(spacing: 9) {
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 27, height: 27)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text("MacVital")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.label)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 20)
        .padding(.bottom, 24)
    }

    private var nav: some View {
        VStack(spacing: 4) {
            ForEach(AppPage.allCases) { page in
                NavRow(
                    page: page,
                    isActive: environment.page == page,
                    badge: badge(for: page)
                ) {
                    environment.page = page
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private func badge(for page: AppPage) -> String? {
        switch page {
        case .junk:
            let bytes = model.totalFoundBytes
            return bytes > 0 ? ByteFormat.compact(bytes) : nil
        case .annotate:
            return environment.screenPen.isActive ? "●" : nil
        default:
            return nil
        }
    }

    private var storage: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Theme.separator)
                .padding(.bottom, 4)
            Text("存储空间")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryLabel)

            if let disk = environment.diskSpace {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.separator)
                        Capsule()
                            .fill(disk.usedFraction > 0.9 ? Theme.junk : Theme.accent)
                            .frame(width: max(geometry.size.width * disk.usedFraction, 3))
                    }
                }
                .frame(height: 4)

                Text("已用 \(ByteFormat.string(disk.used)) / \(ByteFormat.string(disk.total))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryLabel)
            } else {
                Text("读取中…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryLabel)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if environment.permissions.fullDiskAccess != .granted {
                PermissionBanner()
                Divider().overlay(Theme.separator)
            }
            switch environment.page {
            case .dashboard:
                DashboardPage()
            case .junk:
                if case .done(let summary) = model.phase {
                    CleanupSummaryView(summary: summary)
                } else {
                    JunkCleanerPage()
                }
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
                WhiteboardPage()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
    }
}

private struct NavRow: View {
    let page: AppPage
    let isActive: Bool
    let badge: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.symbolName)
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 16)
                Text(page.title)
                    .font(.system(size: 14, weight: isActive ? .medium : .regular))
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(isActive ? .white.opacity(0.85) : Theme.secondaryLabel)
                }
            }
            .foregroundStyle(isActive ? Theme.accent : Theme.secondaryLabel)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                RoundedMarker(isActive: isActive, isHovering: isHovering)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct RoundedMarker: View {
    let isActive: Bool
    let isHovering: Bool

    var body: some View {
        // A tinted fill, not a solid one. Everything else in this window sits
        // at low contrast on purpose; a saturated block was the one thing
        // shouting, and it is not even the thing the user is looking at. This
        // is also what every macOS sidebar does.
        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill(isActive ? Theme.accent.opacity(0.16) : (isHovering ? Theme.accent.opacity(0.08) : Color.clear))
    }
}

// MARK: - Shared page chrome

/// Every page opens with the same title block, per the spec.
struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(Theme.label)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryLabel)
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}
