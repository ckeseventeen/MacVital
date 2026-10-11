import SwiftUI
import MacVitalKit

/// The screen-pen page. Drawing happens in an overlay window above every other
/// app, so this page is the launcher and the settings panel — not a canvas.
struct AnnotatePage: View {
    @Environment(AppEnvironment.self) private var environment
    /// Injected separately from `AppEnvironment`: the pen is its own
    /// `ObservableObject`, and a `let` property on the environment would never
    /// republish when its state changed.
    @Environment(ScreenPenController.self) private var pen

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.sectionSpacing) {
                // Tools, colours, widths and the spotlight are chosen on the
                // floating palette that appears with the pen. This page used
                // to carry a second copy of every one of them.
                toggleCard
                shortcutsCard
            }
            .padding(.horizontal, Theme.Metric.pagePaddingH)
            .padding(.vertical, Theme.Metric.pagePaddingV)
        }
        .navigationSubtitle(pen.isActive ? "正在绘制 · 按 esc 退出" : "在任何窗口上方直接标注")
    }

    // MARK: - Toggle

    private var toggleCard: some View {
        Card {
            HStack(spacing: 16) {
                GlyphTile(
                    systemImage: pen.isActive ? "pencil.tip.crop.circle.fill" : "pencil.tip",
                    tint: Color.orange,
                    size: 46
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(pen.isActive ? "画笔已开启" : "开启屏幕画笔")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.label)
                    Text(pen.isActive
                         ? "覆盖全部显示器。画完的每一笔都可以再选中、移动、擦掉。"
                         : "覆盖全部显示器，鼠标拖动即可绘制。退出后笔迹立即清除。")
                        .font(.body)
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

    // MARK: - Shortcuts

    private var shortcutsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("快捷键")
                    .font(.body.weight(.medium))
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
                            .font(.body)
                            .foregroundStyle(Theme.secondaryLabel)
                        Spacer(minLength: 0)
                    }
                }
                Divider().overlay(Theme.separator).padding(.vertical, 3)
                Text("菜单栏右上角的笔尖图标可以随时开关，不必回到这个窗口。")
                    .font(.callout)
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
}
