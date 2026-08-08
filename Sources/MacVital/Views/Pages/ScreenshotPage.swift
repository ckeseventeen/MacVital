import SwiftUI
import AppKit
import MacVitalKit

struct ScreenshotPage: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var shots: ScreenshotService
    @State private var mode: ScreenshotService.Mode = .region
    @State private var savedTo: URL?

    // Annotation state for the editor.
    @State private var tool: AnnotationTool = .arrow
    @State private var colorIndex = 0
    @State private var widthIndex = 1
    @StateObject private var canvasRef = ScreenshotEditor.CanvasBox()

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

    // MARK: - Before a capture

    private var capturePrompt: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.sectionSpacing) {
                PageHeader(
                    title: "截图",
                    subtitle: shots.isCapturing ? "等待捕获…" : "截完可以直接在图上标注，再决定保存还是丢弃"
                )

                GlassGroup(spacing: Theme.Metric.gridSpacing) {
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
                }

                Card(padding: 40) {
                    VStack(spacing: 16) {
                        GlyphTile(systemImage: "camera.viewfinder", tint: Theme.accent, size: 56)
                        Text("还没有截图")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.label)
                        Text("选区和窗口模式使用系统原生的选择界面，按 esc 取消。全屏模式会先自动隐藏本窗口。")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryLabel)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
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
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryLabel)
            Picker("", selection: $shots.delaySeconds) {
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
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(
                    title: "截图",
                    subtitle: "\(Int(latest.size.width)) × \(Int(latest.size.height)) · \(RelativeDateFormat.string(latest.takenAt))"
                ) {
                    Button("重新截图") { Task { await capture() } }
                        .buttonStyle(.bordered)
                        .disabled(shots.isCapturing)
                }

                AnnotationToolbar(
                    tool: $tool,
                    colorIndex: $colorIndex,
                    widthIndex: $widthIndex,
                    canUndo: canvasRef.canUndo,
                    onUndo: { canvasRef.canvas?.undo() },
                    onRedo: { canvasRef.canvas?.redo() },
                    onClear: { canvasRef.canvas?.clear() }
                )
            }
            .padding(.horizontal, Theme.Metric.pagePaddingH)
            .padding(.top, Theme.Metric.pagePaddingV)
            .padding(.bottom, 16)

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
            .padding(.horizontal, Theme.Metric.pagePaddingH)
            .padding(.bottom, 16)

            Divider().overlay(Theme.separator)
            footer
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let savedTo {
                Label("已保存到 \(savedTo.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.success)
            } else {
                Text("标注会随图片一起保存；丢弃后不留文件")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryLabel)
            }

            Spacer()

            Button("丢弃") {
                shots.discard()
                savedTo = nil
            }
            .buttonStyle(.link)

            Button("拷贝") { copyFlattened() }
                .keyboardShortcut("c", modifiers: [.command, .shift])

            Button {
                savedTo = saveFlattened()
            } label: {
                Text("保存到桌面")
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, Theme.Metric.pagePaddingH)
        .padding(.vertical, Theme.Metric.barPaddingV)
        .glassChrome()
    }

    // MARK: - Actions

    private func capture() async {
        savedTo = nil
        let window = NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
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
                    Spacer(minLength: 0)
                    if isBusy { ProgressView().controlSize(.small) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.label)
                    Text(mode.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryLabel)
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
