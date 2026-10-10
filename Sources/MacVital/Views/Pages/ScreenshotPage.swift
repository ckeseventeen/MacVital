import SwiftUI
import AppKit
import MacVitalKit

struct ScreenshotPage: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ScreenshotService.self) private var shots
    @State private var mode: ScreenshotService.Mode = .region
    @State private var savedTo: URL?

    // Annotation state for the editor.
    @State private var tool: AnnotationTool = .arrow
    @State private var colorIndex = 0
    @State private var widthIndex = 1
    @State private var canvasRef = ScreenshotEditor.CanvasBox()

    private var style: AnnotationStyle {
        AnnotationStyle(
            color: ScreenPenController.palette[colorIndex],
            lineWidth: ScreenPenController.widths[widthIndex]
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if let latest = shots.latest {
                editor(for: latest)
            } else {
                capturePrompt
            }
        }
        .navigationSubtitle(subtitle)
        .toolbar {
            if shots.latest != nil {
                ToolbarItem {
                    Menu {
                        ForEach(ScreenshotService.Mode.allCases) { candidate in
                            Button {
                                mode = candidate
                                Task { await capture() }
                            } label: {
                                Label(candidate.title, systemImage: candidate.symbolName)
                            }
                        }
                    } label: {
                        Label("重新截图", systemImage: "camera.viewfinder")
                    } primaryAction: {
                        Task { await capture() }
                    }
                    .help("用同样的方式再截一张，或从菜单里换一种")
                    .disabled(shots.isCapturing)
                }
            }
        }
        .alert(
            shots.errorNeedsScreenRecording ? "缺少「屏幕录制」权限" : "截图出错",
            isPresented: Binding(
                get: { shots.errorMessage != nil },
                set: { if !$0 { shots.clearError() } }
            )
        ) {
            if shots.errorNeedsScreenRecording {
                Button("打开系统设置") {
                    ScreenCapturePermission.openSettings()
                    shots.clearError()
                }
            }
            Button("好", role: .cancel) { shots.clearError() }
        } message: {
            Text(shots.errorMessage ?? "")
        }
    }

    private var subtitle: String {
        if shots.isCapturing { return "等待捕获…" }
        if let latest = shots.latest {
            return "\(Int(latest.size.width)) × \(Int(latest.size.height)) · \(RelativeDateFormat.string(latest.takenAt))"
        }
        return "截完可以直接在图上标注，再决定保存还是丢弃"
    }

    // MARK: - Before a capture

    private var capturePrompt: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.sectionSpacing) {
                HStack(spacing: Theme.Metric.gridSpacing) {
                    ForEach(ScreenshotService.Mode.allCases) { candidate in
                        ModeCard(
                            mode: candidate,
                            isBusy: shots.isCapturing && mode == candidate
                        ) {
                            mode = candidate
                            Task { await capture() }
                        }
                    }
                }

                Card(padding: 40) {
                    VStack(spacing: 14) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("还没有截图")
                            .font(.title3.weight(.semibold))
                        Text("开始截图后会暂时隐藏 PureMark，显示刚才位于后面的应用。选区和窗口模式按 esc 可取消。")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)
                        delayPicker.padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, Theme.Metric.pagePaddingH)
            .padding(.vertical, Theme.Metric.pagePaddingV)
        }
    }

    private var delayPicker: some View {
        HStack(spacing: 12) {
            Text("延时")
                .foregroundStyle(.secondary)
            Picker("", selection: Bindable(shots).delaySeconds) {
                Text("无").tag(0)
                Text("3 秒").tag(3)
                Text("5 秒").tag(5)
                Text("10 秒").tag(10)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 250)
        }
    }

    // MARK: - Editor

    private func editor(for latest: ScreenshotService.Capture) -> some View {
        VStack(spacing: 0) {
            AnnotationToolbar(
                tool: $tool,
                colorIndex: $colorIndex,
                widthIndex: $widthIndex,
                canUndo: canvasRef.canUndo,
                onUndo: { canvasRef.canvas?.undo() },
                onRedo: { canvasRef.canvas?.redo() },
                onClear: { canvasRef.canvas?.clear() }
            )
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            // The canvas keeps the image's aspect ratio so annotations land
            // where the user aimed; `flattened()` scales them back onto the
            // pixel grid on export.
            ScreenshotEditor(
                image: latest.image,
                tool: tool,
                style: style,
                canvasRef: canvasRef,
                onChange: { savedTo = nil }
            )
            .aspectRatio(latest.size.width / max(latest.size.height, 1), contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            footer
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let savedTo {
                Label("已保存到 \(savedTo.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
            } else {
                Text("标注会随图片一起保存；丢弃后不留文件")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("丢弃") {
                shots.discard()
                savedTo = nil
            }
            .buttonStyle(.link)

            Button("拷贝") { copyFlattened() }
                .keyboardShortcut("c", modifiers: [.command, .shift])

            Button("保存到桌面") {
                savedTo = saveFlattened()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Actions

    private func capture() async {
        savedTo = nil
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        await shots.capture(mode: mode, hiding: window)
    }

    /// Export goes through the canvas so annotations are burned in. Falling
    /// back to the raw capture keeps the buttons working if the canvas has not
    /// been created yet.
    private func copyFlattened() {
        if let flattened = canvasRef.canvas?.flattened() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([flattened])
        } else {
            shots.copyToPasteboard()
        }
    }

    private func saveFlattened() -> URL? {
        guard let flattened = canvasRef.canvas?.flattened() else {
            return shots.saveToDesktop()
        }
        return shots.saveToDesktop(image: flattened)
    }
}

// MARK: - Mode card

private struct ModeCard: View {
    let mode: ScreenshotService.Mode
    let isBusy: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    GlyphTile(systemImage: mode.symbolName, tint: Theme.accent, size: 38)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                    if isBusy { ProgressView().controlSize(.small) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title)
                        .font(.title3.weight(.semibold))
                    Text(mode.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(tinted: isHovering ? Theme.accent : nil)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(isHovering ? Theme.accent.opacity(0.45) : Color.clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .onHover { isHovering = $0 }
    }
}
