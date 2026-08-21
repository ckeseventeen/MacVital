import SwiftUI
import MacVitalKit

struct DashboardPage: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var model: ScanViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.sectionSpacing) {
                greeting
                overview
                quickActions
                systemStatus
            }
            .padding(.horizontal, Theme.Metric.pagePaddingH)
            .padding(.vertical, Theme.Metric.pagePaddingV)
        }
        .task { environment.refreshDiskSpace() }
    }

    // MARK: - Greeting

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Self.timeOfDayGreeting())
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Theme.label)
            Text(statusLine)
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryLabel)
        }
    }

    private static func timeOfDayGreeting() -> String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "早上好"
        case 12..<14: return "中午好"
        case 14..<18: return "下午好"
        case 18..<23: return "晚上好"
        default: return "夜深了"
        }
    }

    private var statusLine: String {
        guard let disk = environment.diskSpace else { return "正在读取磁盘信息…" }
        let free = ByteFormat.string(disk.free)
        if model.totalFoundBytes > 0 {
            return "可用 \(free)，上次扫描发现 \(ByteFormat.string(model.totalFoundBytes)) 可回收。"
        }
        if disk.usedFraction > 0.9 {
            return "可用 \(free)，磁盘快满了，建议扫描一次。"
        }
        return "可用 \(free)，状态良好。"
    }

    // MARK: - Overview

    private var overview: some View {
        HStack(alignment: .center, spacing: 32) {
            storageRing
            statGrid
        }
    }

    private var storageRing: some View {
        ProgressRing(
            value: environment.diskSpace?.usedFraction ?? 0,
            lineWidth: 9,
            tint: (environment.diskSpace?.usedFraction ?? 0) > 0.9 ? Theme.junk : Theme.accent
        ) {
            VStack(spacing: 2) {
                if let disk = environment.diskSpace {
                    Text(ByteFormat.compact(disk.used))
                        .font(.system(size: 26, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.label)
                    Text("已用 / \(ByteFormat.compact(disk.total))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryLabel)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .frame(width: 122, height: 122)
    }

    private var statGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: Theme.Metric.gridSpacing), GridItem(.flexible(), spacing: Theme.Metric.gridSpacing)],
            spacing: Theme.Metric.gridSpacing
        ) {
            ForEach(stats, id: \.label) { stat in
                StatTile(label: stat.label, value: stat.value, dot: stat.dot, valueTint: stat.tint)
            }
        }
    }

    /// The dot encodes *state*, not category.
    ///
    /// It used to be one colour per tile — orange, blue, orange, green — which
    /// looked like a legend and was not one: the same orange meant "space you
    /// could reclaim" on one tile and "files awaiting deletion" on the next.
    /// Four decorative colours are four things for the eye to resolve before
    /// discovering none of them mean anything. Now: coloured means there is
    /// something to act on, grey means there is not.
    private var stats: [(label: String, value: String, dot: Color, tint: Color)] {
        let scanned = model.totalFoundBytes
        let quarantined = environment.quarantineBytes
        let almostFull = (environment.diskSpace?.usedFraction ?? 0) > 0.9

        return [
            (
                "可回收",
                scanned > 0 ? ByteFormat.string(scanned) : "未扫描",
                scanned > 0 ? Theme.junk : Theme.tertiaryLabel,
                scanned > 0 ? Theme.junk : Theme.secondaryLabel
            ),
            (
                "缓存",
                model.findings.isEmpty ? "—" : ByteFormat.string(model.bytes(in: .caches)),
                model.bytes(in: .caches) > 0 ? Theme.accent : Theme.tertiaryLabel,
                model.findings.isEmpty ? Theme.secondaryLabel : Theme.label
            ),
            (
                "隔离区",
                quarantined > 0 ? ByteFormat.string(quarantined) : "空",
                quarantined > 0 ? Theme.accent : Theme.tertiaryLabel,
                quarantined > 0 ? Theme.label : Theme.secondaryLabel
            ),
            (
                "可用空间",
                environment.diskSpace.map { ByteFormat.string($0.free) } ?? "—",
                almostFull ? Theme.junk : Theme.success,
                almostFull ? Theme.junk : Theme.success
            ),
        ]
    }

    // MARK: - Quick actions

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("快捷操作")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.label)

            // Three columns, not two. There are five actions, and two columns
            // left the last one alone on its own row with a hole beside it.
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: Theme.Metric.gridSpacing),
                    count: 3
                ),
                spacing: Theme.Metric.gridSpacing
            ) {
                QuickAction(
                    title: "智能扫描",
                    subtitle: model.isScanning ? "正在扫描…" : "一键找出可回收空间",
                    systemImage: "sparkle.magnifyingglass",
                    tint: Theme.accent
                ) {
                    environment.page = .junk
                    Task { await model.startScan() }
                }
                .disabled(model.isScanning)

                QuickAction(
                    title: "卸载应用",
                    subtitle: "连同散落的配置一起移除",
                    systemImage: "square.grid.2x2",
                    tint: Color(hex: 0x534AB7)
                ) {
                    environment.page = .uninstall
                }

                QuickAction(
                    title: "截图",
                    subtitle: "选区 · 全屏 · 窗口",
                    systemImage: "camera.viewfinder",
                    tint: Theme.success
                ) {
                    environment.page = .screenshot
                }

                QuickAction(
                    title: environment.screenPen.isActive ? "退出画笔" : "屏幕画笔",
                    subtitle: environment.screenPen.isActive ? "按 esc 也可退出" : "在屏幕上直接标注",
                    systemImage: "pencil.tip",
                    tint: Color(hex: 0xBA7517)
                ) {
                    environment.screenPen.toggle()
                }

                QuickAction(
                    title: "隔离区",
                    subtitle: environment.quarantineBytes > 0
                        ? "\(ByteFormat.string(environment.quarantineBytes)) 待清除"
                        : "已清空",
                    systemImage: "clock.arrow.circlepath",
                    tint: Theme.success
                ) {
                    environment.showQuarantine = true
                }
            }
        }
    }
}

// MARK: - System status

extension DashboardPage {

    /// What the app can and cannot do on this machine right now.
    ///
    /// Not filler. Full Disk Access decides whether a scan sees most of
    /// `~/Library` at all — the README spends a section on it — and the
    /// privileged helper decides whether anything under `/Library` can be
    /// touched. Both were discoverable only by running into them: a scan came
    /// back thin, or a row was locked, and nothing on the overview said why.
    ///
    /// It also gives the page a bottom. The dashboard ended two-thirds of the
    /// way down a tall window, which read as unfinished.
    fileprivate var systemStatus: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("系统状态")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.label)

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: Theme.Metric.gridSpacing),
                    count: 3
                ),
                spacing: Theme.Metric.gridSpacing
            ) {
                StatusTile(
                    title: "完整磁盘访问",
                    detail: fullDiskDetail,
                    systemImage: "externaldrive.badge.person.crop",
                    state: fullDiskState
                )
                StatusTile(
                    title: "特权助手",
                    detail: environment.helperStatus.summary,
                    systemImage: "key",
                    state: environment.helperStatus == .enabled ? .good
                        : (environment.helperStatus == .unsupported ? .unavailable : .attention)
                )
                StatusTile(
                    title: "隔离区保留",
                    detail: "\(environment.settings.retentionDays) 天后自动清除",
                    systemImage: "clock.arrow.circlepath",
                    state: .good
                )
            }
        }
    }

    private var fullDiskState: StatusTile.State {
        switch environment.permissions.fullDiskAccess {
        case .granted: return .good
        case .denied: return .attention
        case .unknown: return .unavailable
        }
    }

    private var fullDiskDetail: String {
        switch environment.permissions.fullDiskAccess {
        case .granted: return "已授权，扫描可以看到完整的 ~/Library"
        case .denied: return "未授权，扫描结果会严重偏少"
        case .unknown: return "无法确定，可在设置中重新检测"
        }
    }
}

/// One line of "can the app do this here", with the reason attached.
private struct StatusTile: View {
    enum State {
        case good
        case attention
        /// Not a problem to fix — a property of this build or machine.
        case unavailable

        var tint: Color {
            switch self {
            case .good: return Theme.success
            case .attention: return Theme.junk
            case .unavailable: return Theme.secondaryLabel
            }
        }

        var symbol: String {
            switch self {
            case .good: return "checkmark.circle.fill"
            case .attention: return "exclamationmark.triangle.fill"
            case .unavailable: return "minus.circle.fill"
            }
        }
    }

    let title: String
    let detail: String
    let systemImage: String
    let state: State

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryLabel)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.label)
                Spacer(minLength: 0)
                Image(systemName: state.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(state.tint)
            }
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .well(cornerRadius: Theme.Radius.card)
    }
}

// MARK: - Pieces

private struct StatTile: View {
    let label: String
    let value: String
    let dot: Color
    let valueTint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(dot)
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryLabel)
            }
            Text(value)
                .font(.system(size: 19, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(valueTint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }
}

private struct QuickAction: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                GlyphTile(systemImage: systemImage, tint: tint, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.label)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryLabel)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(tinted: isHovering ? tint : nil)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(isHovering ? tint.opacity(0.4) : Color.clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovering = $0 && isEnabled }
    }
}
