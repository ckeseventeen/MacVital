import SwiftUI
import MacVitalKit

struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("通用", systemImage: "gearshape") }
            AdvisorSettings()
                .tabItem { Label("AI 判定", systemImage: "sparkles") }
            ScanSettings()
                .tabItem { Label("扫描", systemImage: "magnifyingglass") }
            SafetySettings()
                .tabItem { Label("安全", systemImage: "shield") }
        }
        .padding(20)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("外观", selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbolName).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text("外观")
            } footer: {
                Text("默认跟随系统的浅色/深色设置。这里的选择只影响 MacVital 自己。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("在菜单栏显示网速", isOn: $settings.showMenuBarSpeed)
                    .onChange(of: settings.showMenuBarSpeed) { _, _ in
                        environment.applyMenuBarSetting()
                    }
                Toggle("在菜单栏显示屏幕画笔", isOn: $settings.showMenuBarPen)
                    .onChange(of: settings.showMenuBarPen) { _, _ in
                        environment.applyMenuBarSetting()
                    }
            } header: {
                Text("菜单栏")
            } footer: {
                Text("网速每秒读取一次网卡计数器，点开还能看到可用空间和隔离区占用。画笔图标一点即开，esc 退出。两者关闭后都不再占用资源。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Advisor

struct AdvisorSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var apiKeyDraft: String = ""
    @State private var localReachable: Bool?

    var body: some View {
        Form {
            Section {
                Picker("判定方式", selection: $settings.advisorMode) {
                    ForEach(AdvisorMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(settings.advisorMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("解释与归因")
            } footer: {
                Text("无论选哪一种，模型都只负责解释、归因和排序。是否允许删除始终由内置的确定性规则引擎判定。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if settings.advisorMode == .local {
                Section("本地模型") {
                    TextField("地址", text: $settings.localModelEndpoint)
                    TextField("模型名", text: $settings.localModelName)
                    HStack {
                        Button("测试连接") { Task { await testLocal() } }
                        if let localReachable {
                            Label(
                                localReachable ? "可以连接" : "连接失败",
                                systemImage: localReachable ? "checkmark.circle" : "xmark.circle"
                            )
                            .foregroundStyle(localReachable ? .green : .red)
                            .font(.caption)
                        }
                    }
                    Text("地址必须指向 127.0.0.1。指向其他主机会被直接拒绝，以免把文件路径发到本机之外。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if settings.advisorMode == .cloud {
                Section("Anthropic API") {
                    SecureField("API Key", text: $apiKeyDraft, prompt: Text(settings.hasCloudKey ? "已保存（留空则不修改）" : "sk-ant-..."))
                    HStack {
                        Button("保存") {
                            settings.setCloudKey(apiKeyDraft)
                            apiKeyDraft = ""
                        }
                        .disabled(apiKeyDraft.isEmpty)
                        Button("清除", role: .destructive) {
                            settings.setCloudKey(nil)
                            apiKeyDraft = ""
                        }
                        .disabled(!settings.hasCloudKey)
                    }
                    Text("Key 保存在系统钥匙串，不会写入配置文件。发送到云端的只有脱敏后的元数据：路径中的用户名会替换为 <user>，文件内容不会上传。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func testLocal() async {
        guard let url = URL(string: settings.localModelEndpoint) else {
            localReachable = false
            return
        }
        let advisor = LocalModelAdvisor(configuration: .init(endpoint: url, model: settings.localModelName))
        localReachable = await advisor.ping()
    }
}

// MARK: - Scan

struct ScanSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var rootsDraft: String = ""

    var body: some View {
        Form {
            Section("项目目录") {
                TextEditor(text: $rootsDraft)
                    .font(.callout.monospaced())
                    .frame(height: 110)
                HStack {
                    Button("保存") {
                        settings.projectRoots = rootsDraft
                            .split(separator: "\n")
                            .map { String($0).trimmingCharacters(in: .whitespaces) }
                    }
                    Button("恢复默认") {
                        settings.projectRoots = []
                        rootsDraft = ScanOptions().projectRoots.joined(separator: "\n")
                    }
                }
                Text("每行一个目录。MacVital 只在这些目录下搜索 node_modules、Pods、target 等构建产物。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("阈值") {
                Stepper(
                    "大文件阈值：\(settings.largeFileThresholdMB) MB",
                    value: $settings.largeFileThresholdMB,
                    in: 50...4096,
                    step: 50
                )
                Stepper(
                    "项目搜索深度：\(settings.projectSearchDepth) 层",
                    value: $settings.projectSearchDepth,
                    in: 2...8
                )
            }
        }
        .formStyle(.grouped)
        .onAppear { rootsDraft = settings.projectRoots.joined(separator: "\n") }
    }
}

// MARK: - Safety

struct SafetySettings: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("隔离区") {
                Stepper(
                    "保留天数：\(settings.retentionDays) 天",
                    value: $settings.retentionDays,
                    in: 1...30
                )
                Text("移入隔离区的文件在保留期内随时可以还原，到期后才真正删除。改动只影响之后的清理操作。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("当前占用", value: ByteFormat.string(environment.quarantineBytes))
            }

            Section("特权助手") {
                LabeledContent("状态", value: environment.helperStatus.summary)
                HStack {
                    Button("安装") { environment.installHelper() }
                        .disabled(environment.helperStatus == .enabled)
                    Button("卸载", role: .destructive) {
                        Task { await environment.removeHelper() }
                    }
                    .disabled(environment.helperStatus == .notRegistered)
                    Button("刷新状态") { environment.refreshHelperStatus() }
                }
                Text("主程序永远以普通用户身份运行。只有清理 /Library 下的系统级残留时才会调用助手，且助手会用同一套规则再校验一遍路径。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("权限") {
                LabeledContent("完整磁盘访问") {
                    switch environment.permissions.fullDiskAccess {
                    case .granted: Label("已授权", systemImage: "checkmark.circle").foregroundStyle(.green)
                    case .denied: Label("未授权", systemImage: "xmark.circle").foregroundStyle(.orange)
                    case .unknown: Text("未知")
                    }
                }
                Button("打开系统设置") { environment.permissions.openSystemSettings() }
            }
        }
        .formStyle(.grouped)
        .onAppear { environment.permissions.refresh() }
    }
}
