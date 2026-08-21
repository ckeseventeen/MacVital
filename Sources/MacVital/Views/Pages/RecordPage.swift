import SwiftUI
import AppKit
import MacVitalKit

/// Recording and LAN broadcast. Both are ScreenCaptureKit sessions, so they
/// share a page — and they run independently, so you can record what you are
/// broadcasting.
struct RecordPage: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var recorder: ScreenRecorder
    @EnvironmentObject private var live: LiveBroadcaster
    @State private var savedTo: URL?
    @State private var elapsed: TimeInterval = 0

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.sectionSpacing) {
                PageHeader(title: "录屏与直播", subtitle: subtitle)
                recordCard
                if let latest = recorder.latest { resultCard(latest) }
                liveCard
            }
            .padding(.horizontal, Theme.Metric.pagePaddingH)
            .padding(.vertical, Theme.Metric.pagePaddingV)
        }
        .onReceive(ticker) { _ in
            if case .recording(let since) = recorder.state {
                elapsed = Date().timeIntervalSince(since)
            }
        }
        .alert(
            "出错了",
            isPresented: Binding(
                get: { recorder.errorMessage != nil || live.errorMessage != nil },
                set: { if !$0 { recorder.errorMessage = nil; live.errorMessage = nil } }
            )
        ) {
            Button("好") { recorder.errorMessage = nil; live.errorMessage = nil }
        } message: {
            Text(recorder.errorMessage ?? live.errorMessage ?? "")
        }
    }

    private var subtitle: String {
        if recorder.state.isRecording { return "正在录制 \(Self.clock(elapsed))" }
        if live.isBroadcasting { return "正在直播 · \(live.viewerCount) 位观众" }
        return "录制成 MP4，或把屏幕直接播到局域网里的其他设备"
    }

    // MARK: - Record

    private var recordCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    GlyphTile(
                        systemImage: recorder.state.isRecording ? "record.circle.fill" : "record.circle",
                        tint: Theme.junk,
                        size: 46
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(recorder.state.isRecording ? "正在录制" : "录制屏幕")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.label)
                        Text(recorder.state.isRecording
                             ? "已录 \(Self.clock(elapsed)) · MacVital 自己的窗口不会出现在画面里"
                             : "全屏录制为 H.264 MP4，本窗口会自动从画面中排除。")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button(recorder.state.isRecording ? "停止" : "开始录制") {
                        Task {
                            if recorder.state.isRecording {
                                await recorder.stop()
                            } else {
                                savedTo = nil
                                elapsed = 0
                                await recorder.start(excluding: mainWindow)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(recorder.state.isRecording ? Theme.junk : Theme.accent)
                    .disabled(recorder.state == .starting || recorder.state == .stopping)
                }

                if !recorder.state.isBusy {
                    HStack(spacing: 22) {
                        HStack(spacing: 10) {
                            Text("帧率")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.secondaryLabel)
                            Picker("", selection: $recorder.frameRate) {
                                Text("30 fps").tag(30)
                                Text("60 fps").tag(60)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 170)
                        }
                        Toggle("包含鼠标指针", isOn: $recorder.showsCursor)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .font(.system(size: 13))
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func resultCard(_ latest: ScreenRecorder.Recording) -> some View {
        Card {
            HStack(spacing: 16) {
                GlyphTile(systemImage: "film", tint: Theme.success, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("录制完成 · \(Self.clock(latest.duration))")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.label)
                    Text("\(Int(latest.size.width)) × \(Int(latest.size.height)) · \(ByteFormat.string(latest.bytes))")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryLabel)
                    if let savedTo {
                        Label("已保存到「影片」/\(savedTo.lastPathComponent)", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.success)
                    }
                }
                Spacer(minLength: 0)
                Button("丢弃") { recorder.discard(); savedTo = nil }
                    .buttonStyle(.link)
                Button("在访达中显示") { recorder.revealLatest() }
                Button("保存到影片") { savedTo = recorder.saveToMovies() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Live

    private var liveCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    GlyphTile(
                        systemImage: live.isBroadcasting ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right",
                        tint: Color(hex: 0x534AB7),
                        size: 46
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(live.isBroadcasting ? "正在直播" : "局域网直播")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.label)
                        Text(live.isBroadcasting
                             ? "\(live.viewerCount) 位观众正在观看"
                             : "同一网络下的任何设备用浏览器打开链接即可观看，不需要装任何东西。")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button(live.isBroadcasting ? "停止直播" : "开始直播") {
                        Task { await live.toggle(excluding: mainWindow) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(live.isBroadcasting ? Theme.junk : Color(hex: 0x534AB7))
                }

                if live.isBroadcasting {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("在其他设备的浏览器里打开")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryLabel)
                        ForEach(live.addresses, id: \.self) { address in
                            HStack(spacing: 10) {
                                // The URL carries the session token — see
                                // `LiveBroadcaster.viewerURL`. Building it by
                                // hand here would hand out a link that 404s.
                                Text(live.viewerURL(for: address))
                                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                                    .textSelection(.enabled)
                                    .foregroundStyle(Theme.accent)
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(live.viewerURL(for: address), forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.plain)
                                .help("拷贝链接")
                                Spacer(minLength: 0)
                            }
                        }
                        if live.addresses.isEmpty {
                            Text("没有检测到局域网地址，可能未连接网络。")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.junk)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .well()
                } else {
                    HStack(spacing: 22) {
                        HStack(spacing: 10) {
                            Text("帧率")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.secondaryLabel)
                            Picker("", selection: $live.frameRate) {
                                Text("8").tag(8)
                                Text("12").tag(12)
                                Text("20").tag(20)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 150)
                        }
                        HStack(spacing: 10) {
                            Text("画质")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.secondaryLabel)
                            Slider(value: $live.quality, in: 0.3...0.9)
                                .frame(width: 130)
                        }
                        Spacer(minLength: 0)
                    }
                }

                Label(
                    "这是局域网直播（MJPEG over HTTP），不是推流到 Twitch / YouTube / B 站——那需要 RTMP，macOS 没有对应框架。首次开启时系统防火墙可能会询问是否允许接入连接。",
                    systemImage: "info.circle"
                )
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Helpers

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
