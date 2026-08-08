import SwiftUI
import MacVitalKit

/// Hosts the shell and every sheet. The shell itself is layout only — sheet
/// state lives on `AppEnvironment` because more than one page raises them.
struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var model: ScanViewModel

    var body: some View {
        AppShell()
            .sheet(isPresented: $environment.showConfirm) {
                ConfirmSheet(isPresented: $environment.showConfirm)
                    .environmentObject(model)
                    .environmentObject(environment)
            }
            .sheet(isPresented: $environment.showQuarantine) {
                QuarantineView(isPresented: $environment.showQuarantine, environment: environment)
            }
            .alert(
                "扫描出错",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                )
            ) {
                Button("好") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
    }
}

// MARK: - Permission banner

/// Shown while Full Disk Access is missing — or while the app cannot tell.
///
/// Two things this banner must not do, both of which earlier versions did:
///
/// 1. **Claim knowledge it does not have.** `.unknown` and `.denied` are
///    worded differently, because a machine where every probe was merely
///    absent used to get told flatly that the permission was missing.
/// 2. **Offer an action that cannot work.** Full Disk Access is bound at
///    process launch, so re-probing can never observe a grant the user just
///    made. "Re-check" is still here — pressing it and seeing nothing change
///    is the honest outcome — but the banner now says why, and relaunching is
///    the prominent action rather than one hidden behind having visited
///    Settings first.
struct PermissionBanner: View {
    @EnvironmentObject private var environment: AppEnvironment

    private var permissions: PermissionsCoordinator { environment.permissions }
    private var isDenied: Bool { permissions.fullDiskAccess == .denied }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 11) {
                Image(systemName: isDenied ? "lock.shield.fill" : "questionmark.circle.fill")
                    .foregroundStyle(isDenied ? Theme.junk : Theme.secondaryLabel)

                VStack(alignment: .leading, spacing: 1) {
                    Text(isDenied ? "未获得「完整磁盘访问权限」" : "无法确认是否已获得「完整磁盘访问权限」")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.label)
                    Text(isDenied
                         ? "~/Library 下的绝大部分内容不可见，扫描结果会严重偏少。"
                         : "扫描仍会正常进行；如果结果明显偏少，多半是缺这个权限。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryLabel)
                }

                Spacer(minLength: 8)

                Button("重新检测") { permissions.refresh() }
                    .controlSize(.small)

                Button("前往设置") { permissions.openSystemSettings() }
                    .controlSize(.small)

                Button("授权后重启") { permissions.relaunch() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }

            if isDenied {
                BannerNote(
                    "授权后必须重启 App 才会生效 —— macOS 只在进程启动时授予这个权限，"
                    + "所以在当前进程里点「重新检测」不会变化，这不是检测失败。"
                    + (permissions.lastCheckedAt.map {
                        " 上次检测 " + $0.formatted(date: .omitted, time: .standard) + "，仍未获得。"
                    } ?? "")
                )

                // Only worth saying on a build that has no stable identity for
                // TCC to key on — on a signed build the grant survives updates
                // and this advice would be noise.
                if permissions.isUnsignedBuild {
                    BannerNote(
                        "这是未签名的本地构建：macOS 只能按可执行文件的哈希记住授权，"
                        + "而每次重新编译哈希都会变。如果设置里已经有 MacVital 却依然显示未获得，"
                        + "请先用「−」把它移除，再重新添加当前这份 /Applications/MacVital.app。",
                        icon: "exclamationmark.triangle.fill"
                    )
                }
            }
        }
        .padding(.horizontal, Theme.Metric.pagePaddingH)
        .padding(.vertical, 9)
        .background((isDenied ? Theme.junk : Color.secondary).opacity(0.09))
    }
}

/// A secondary explanatory line under the banner headline.
private struct BannerNote: View {
    let text: String
    var icon: String = "info.circle"

    init(_ text: String, icon: String = "info.circle") {
        self.text = text
        self.icon = icon
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.secondaryLabel)
        .padding(.leading, 25)
    }
}

// MARK: - Cleanup summary

/// Shown as an overlay on the junk page after a run.
struct CleanupSummaryView: View {
    let summary: ScanViewModel.CleanupSummary
    @EnvironmentObject private var model: ScanViewModel
    @EnvironmentObject private var environment: AppEnvironment
    @State private var showSkipped = false

    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(.white, Theme.success)
                .background(Circle().fill(Theme.success.opacity(0.15)).frame(width: 74, height: 74))
                .padding(.bottom, 8)

            Text("已回收 \(ByteFormat.string(summary.reclaimedBytes))")
                .font(.system(size: 27, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.label)

            Text("\(summary.removedCount) 项已移入隔离区，\(environment.settings.retentionDays) 天后自动删除。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryLabel)

            if !summary.skipped.isEmpty {
                DisclosureGroup(isExpanded: $showSkipped) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(summary.skipped, id: \.self) { line in
                            Text(line)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondaryLabel)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                } label: {
                    Label("\(summary.skipped.count) 项被跳过", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 13))
                }
                .frame(maxWidth: 420)
            }

            HStack(spacing: 10) {
                Button("查看隔离区") { environment.showQuarantine = true }
                Button("完成") { model.dismissSummary() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
    }
}
