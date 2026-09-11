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
        .background(Theme.canvas)
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
            // The real app icon, not an impression of it.
            //
            // This was `internaldrive.fill` on a flat `Theme.accent` square: a
            // different glyph from the one the icon draws, on a different blue,
            // with a different corner radius. Nobody had to get it wrong for
            // them to diverge — the icon was redrawn and this stayed where it
            // was, which is what a hand-built copy of another asset always
            // eventually does. Reading the icon means it cannot drift again.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            Text("PureMark")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.label)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 20)
        .padding(.bottom, 24)
    }

    private var nav: some View {
        VStack(alignment: .leading, spacing: 14) {
            navRow(.dashboard)
            navSection("维护", pages: [.junk, .uninstall, .startup])
            navSection("捕获", pages: [.screenshot, .record])
            navSection("创作", pages: [.annotate, .whiteboard])
        }
        .padding(.horizontal, 12)
    }

    private func navSection(_ title: String, pages: [AppPage]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(Theme.tertiaryLabel)
                .padding(.leading, 11)
                .accessibilityAddTraits(.isHeader)
            ForEach(pages) { navRow($0) }
        }
    }

    private func navRow(_ page: AppPage) -> some View {
        NavRow(
            page: page,
            isActive: environment.page == page,
            badge: badge(for: page)
        ) {
            environment.page = page
        }
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
                .font(.system(size: 12))
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
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryLabel)
            } else {
                Text("读取中…")
                    .font(.system(size: 12))
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
                WhiteboardPage(model: environment.whiteboard)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GlassBackdrop())
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
            HStack(spacing: 9) {
                Image(systemName: page.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isActive ? Color.white : Theme.secondaryLabel)
                    .frame(width: 27, height: 27)
                    .background(
                        isActive ? Theme.accent : Theme.well,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                Text(page.title)
                    .font(.system(size: 15, weight: isActive ? .medium : .regular))
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(isActive ? Theme.accent : Theme.secondaryLabel)
                }
            }
            .foregroundStyle(isActive ? Theme.label : Theme.secondaryLabel)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
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
    var systemImage: String?
    @ViewBuilder var trailing: Trailing

    init(
        title: String,
        subtitle: String,
        systemImage: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.trailing = trailing()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 14) {
                titleBlock
                Spacer(minLength: 12)
                trailing
            }
            VStack(alignment: .leading, spacing: 12) {
                titleBlock
                trailing
            }
        }
    }

    private var titleBlock: some View {
        HStack(spacing: 12) {
            if let systemImage {
                GlyphTile(systemImage: systemImage, tint: Theme.accent, size: 38)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: Theme.Text.title, weight: .medium))
                    .foregroundStyle(Theme.label)
                Text(subtitle)
                    .font(.system(size: Theme.Text.caption))
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(2)
            }
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String, systemImage: String? = nil) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage) { EmptyView() }
    }
}
