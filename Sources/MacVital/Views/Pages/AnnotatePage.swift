import SwiftUI
import MacVitalKit

/// The screen-pen page. Drawing happens in an overlay window above every other
/// app, so this page is the launcher and the settings panel — not a canvas.
struct AnnotatePage: View {
    @EnvironmentObject private var environment: AppEnvironment
    /// Injected separately from `AppEnvironment`: the pen is its own
    /// `ObservableObject`, and a `let` property on the environment would never
    /// republish when its state changed.
    @EnvironmentObject private var pen: ScreenPenController

    private let tools: [AnnotationTool] = [.select, .pen, .highlighter, .rectangle, .ellipse, .arrow, .text, .eraser]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.sectionSpacing) {
                PageHeader(
                    title: "屏幕画笔",
                    subtitle: pen.isActive ? "正在绘制 · 按 esc 退出" : "在任何窗口上方直接标注"
                )
                toggleCard
                toolsCard
                focusCard
                shortcutsCard
            }
            .padding(.horizontal, Theme.Metric.pagePaddingH)
            .padding(.vertical, Theme.Metric.pagePaddingV)
        }
    }

    // MARK: - Toggle

    private var toggleCard: some View {
        Card {
            HStack(spacing: 16) {
                GlyphTile(
                    systemImage: pen.isActive ? "pencil.tip.crop.circle.fill" : "pencil.tip",
                    tint: Color(hex: 0xBA7517),
                    size: 46
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(pen.isActive ? "画笔已开启" : "开启屏幕画笔")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.label)
                    Text(pen.isActive
                         ? "覆盖全部显示器。画完的每一笔都可以再选中、移动、擦掉。"
                         : "覆盖全部显示器，鼠标拖动即可绘制。退出后笔迹立即清除。")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(pen.isActive ? "退出" : "开启") { pen.toggle() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }

    // MARK: - Tools

    private var toolsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 18) {
                Text("工具")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.label)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                    spacing: 10
                ) {
                    ForEach(tools) { candidate in
                        ToolChip(tool: candidate, isOn: pen.tool == candidate) {
                            pen.tool = candidate
                        }
                    }
                }

                labelledRow("颜色") {
                    ForEach(Array(ScreenPenController.palette.enumerated()), id: \.offset) { index, color in
                        Button { pen.colorIndex = index } label: {
                            Circle()
                                .fill(Color(nsColor: color))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(Theme.label, lineWidth: pen.colorIndex == index ? 2 : 0))
                                .overlay(Circle().strokeBorder(Theme.separator, lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }

                labelledRow("粗细") {
                    ForEach(Array(ScreenPenController.widths.enumerated()), id: \.offset) { index, width in
                        Button { pen.widthIndex = index } label: {
                            Circle()
                                .fill(pen.widthIndex == index ? pen.currentColor : Theme.secondaryLabel)
                                .frame(width: width + 5, height: width + 5)
                                .frame(width: 30, height: 30)
                                .background(
                                    pen.widthIndex == index ? Theme.accent.opacity(0.12) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Focus

    private var focusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("聚光灯与遮罩")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.label)
                    Text("把屏幕其余部分压暗，只留下你要讲的那一块。压暗层在画笔之下，亮区里照样能画。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    ForEach(FocusMode.allCases) { mode in
                        FocusChip(mode: mode, isOn: pen.focusMode == mode) {
                            pen.focusMode = mode
                        }
                    }
                }

                if pen.focusMode == .mask {
                    Label("遮罩模式下，切到「选择」工具再拖动即可改变亮区范围。", systemImage: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiaryLabel)
                }
            }
        }
    }

    // MARK: - Shortcuts

    private var shortcutsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("快捷键")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.label)
                ForEach(shortcuts, id: \.key) { shortcut in
                    HStack(spacing: 14) {
                        Text(shortcut.key)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .well(cornerRadius: 6)
                            .foregroundStyle(Theme.label)
                            .frame(width: 74, alignment: .leading)
                        Text(shortcut.action)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryLabel)
                        Spacer(minLength: 0)
                    }
                }
                Divider().overlay(Theme.separator).padding(.vertical, 3)
                Text("菜单栏右上角的笔尖图标可以随时开关，不必回到这个窗口。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var shortcuts: [(key: String, action: String)] {
        [
            ("esc", "退出画笔"),
            ("⌘Z", "撤销"),
            ("⇧⌘Z", "重做"),
            ("delete", "删除选中的标注"),
        ]
    }

    // MARK: - Helper

    private func labelledRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryLabel)
                .frame(width: 34, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Chips

private struct ToolChip: View {
    let tool: AnnotationTool
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: tool.symbolName)
                    .font(.system(size: 16))
                Text(tool.title)
                    .font(.system(size: 12))
            }
            .foregroundStyle(isOn ? Color.white : Theme.label)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                isOn ? Theme.accent : Theme.well,
                in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct FocusChip: View {
    let mode: FocusMode
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.title)
                        .font(.system(size: 13, weight: .medium))
                    Text(mode.detail)
                        .font(.system(size: 11))
                        .opacity(0.8)
                }
            }
            .foregroundStyle(isOn ? Color.white : Theme.label)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                isOn ? Theme.accent : Theme.well,
                in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
