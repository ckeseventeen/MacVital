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
        .frame(width: 140, height: 140)
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

    private var stats: [(label: String, value: String, dot: Color, tint: Color)] {
        let scanned = model.totalFoundBytes
        return [
            (
                "可回收",
                scanned > 0 ? ByteFormat.string(scanned) : "未扫描",
                Theme.junk,
                scanned > 0 ? Theme.junk : Theme.secondaryLabel
            ),
            (
                "缓存",
                model.findings.isEmpty ? "—" : ByteFormat.string(model.bytes(in: .caches)),
                ScanCategory.caches.tint,
                Theme.label
            ),
            (
                "隔离区",
                environment.quarantineBytes > 0 ? ByteFormat.string(environment.quarantineBytes) : "空",
                ScanCategory.appResidue.tint,
                Theme.label
            ),
            (
                "可用空间",
                environment.diskSpace.map { ByteFormat.string($0.free) } ?? "—",
                Theme.success,
                Theme.success
            ),
        ]
    }

    // MARK: - Quick actions

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("快捷操作")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.label)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: Theme.Metric.gridSpacing),
                          GridItem(.flexible(), spacing: Theme.Metric.gridSpacing)],
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
