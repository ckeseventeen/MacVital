import SwiftUI
import MacVitalKit

struct DashboardPage: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ScanViewModel.self) private var model

    var body: some View {
        // Storage, what a scan can give back, and the one thing to do about
        // it. This page used to also repeat the sidebar as a grid of quick
        // actions and repeat the permission banner and Settings as status
        // cards; all three were ways to reach things already one click away.
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            overview
            primaryAction
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, Theme.Metric.pagePaddingH)
        .padding(.vertical, Theme.Metric.pagePaddingV)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationSubtitle(statusLine)
        .task { environment.refreshDiskSpace() }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if model.isScanning {
            Button("正在扫描…") { environment.page = .junk }
                .controlSize(.large)
        } else if !model.findings.isEmpty {
            Button("查看可回收项目") { environment.page = .junk }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        } else {
            Button("扫描可回收空间") {
                environment.page = .junk
                Task { await model.startScan() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isCleaning)
        }
    }

    private var statusLine: String {
        guard let disk = environment.diskSpace else { return "正在读取磁盘信息…" }
        let free = ByteFormat.string(disk.free)
        if model.totalFoundBytes > 0 {
            return "可用 \(free) · 上次扫描发现 \(ByteFormat.string(model.totalFoundBytes)) 可回收"
        }
        if disk.usedFraction > 0.9 {
            return "可用 \(free) · 磁盘快满了，建议扫描一次"
        }
        return "可用 \(free)"
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
                        .font(.title.weight(.medium))
                        .monospacedDigit()
                    Text("已用 / \(ByteFormat.compact(disk.total))")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .frame(width: 122, height: 122)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("存储空间")
        .accessibilityValue(environment.diskSpace.map {
            "已用 \(ByteFormat.string($0.used))，共 \(ByteFormat.string($0.total))"
        } ?? "正在读取")
    }

    private var statGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: Theme.Metric.gridSpacing), GridItem(.flexible(), spacing: Theme.Metric.gridSpacing)],
            spacing: Theme.Metric.gridSpacing
        ) {
            ForEach(stats, id: \.label) { stat in
                if stat.label == "隔离区" {
                    // The way into the quarantine from the window, now that
                    // the quick-action grid that carried it is gone.
                    Button { environment.showQuarantine = true } label: {
                        StatTile(label: stat.label, value: stat.value, dot: stat.dot,
                                 valueTint: stat.tint, showsDisclosure: true)
                    }
                    .buttonStyle(.plain)
                    .help("打开隔离区（⇧⌘K）")
                } else {
                    StatTile(label: stat.label, value: stat.value, dot: stat.dot, valueTint: stat.tint)
                }
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
}

// MARK: - Pieces

private struct StatTile: View {
    let label: String
    let value: String
    let dot: Color
    let valueTint: Color
    var showsDisclosure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(dot)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if showsDisclosure {
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            Text(value)
                .font(.title2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(valueTint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxHeight: .infinity)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }
}
