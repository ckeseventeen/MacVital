# MacVital

macOS 空间清理与演示工具。核心不是「能删」，而是**敢删且不出事**。

清理类工具的难点从来不是找到文件，而是证明这个文件可以删。MacVital 把「能不能删」做成了一条确定性的、可审计的、默认拒绝的规则链——模型只负责解释，用户只负责授权，三者取交集才执行，而且执行本身也不是删除，是移进可还原的隔离区。

---

## 功能

八个页面，两类东西。

### 清理

| 功能 | 说明 |
|---|---|
| **垃圾清理** | 开发者残留（DerivedData、node_modules、各语言包管理器缓存）、卸载残留、大文件、重复文件、App 缓存 |
| **卸载应用** | 选定一个 App，连同它散落在 16 个位置的配置、容器、扩展、启动项、安装回执一起移除 |
| **开机启动项** | 列出 LaunchAgents / LaunchDaemons，标出目标程序已不存在的失效条目，一键停用 |

### 演示

| 功能 | 说明 |
|---|---|
| **截图** | 选区 / 全屏 / 窗口，可延时；截完直接在图上标注 |
| **屏幕画笔** | 覆盖全部显示器直接标注，含聚光灯与遮罩 |
| **录屏** | ScreenCaptureKit 直出 H.264 MP4 |
| **局域网直播** | 把屏幕播到同网络的任何浏览器，不需要对方装东西 |
| **白板** | 多块板，可导入图片、导出 PNG / PDF |

菜单栏另有实时网速和画笔开关。

---

## 文档

- **[docs/SAFETY.md](docs/SAFETY.md)** —— 安全模型。想加功能或想审计它会不会删错东西，读这个。
- **[docs/SIGNING.md](docs/SIGNING.md)** —— 签名与权限。签名方式决定 App 能不能拿到完整磁盘访问权限、特权助手能不能工作。

---

## 安全模型

这是这个项目真正的内容，细节见 [docs/SAFETY.md](docs/SAFETY.md)。

### 三层分工，缺一层就不执行删除

| 层 | 负责 | 不负责 | 实现 |
|---|---|---|---|
| **规则引擎** | 能不能删 | 解释、排序 | `RuleEngine` + `RuleCatalog` |
| **AI 层** | 解释、归因、排序、置信度 | 准入 | `AIAdvisor` 及其实现 |
| **用户** | 授权 | — | `ConfirmSheet` |

```
用户勾选 ∩ 规则引擎准入（执行前重新判定） ∩ 模型建议（仅影响默认勾选）
```

**模型的输出永远无法把 deny 变成 allow**——`AIAdvisor` 协议里根本没有能返回准入的方法。

### 规则引擎：默认拒绝

全部 85 条规则在 [RuleCatalog.swift](Sources/MacVitalKit/Rules/RuleCatalog.swift) 一个文件里。不在这份白名单里的路径，任何扫描器都提不出来，任何用户手势也选不中。

`RuleEngine.evaluate` 是唯一的准入闸门，10 道检查按顺序执行，任何一道都只能降级、不能升级：

1. 规则必须存在（未知规则 → 拒绝，扫描器的 bug 不该变成删除）
2. **结构性拒绝清单（按声称路径）**——不依赖磁盘状态，符号链接洗不过去
3. 解析真实路径；是符号链接就直接拒绝，绝不跟随
4. 同一份拒绝清单，再按解析后的路径判一次
5. 问文件系统本身：`st_flags` 里的 `SF_RESTRICTED` / `UF_IMMUTABLE` / `UF_DATAVAULT`
6. 自我保护：隔离区和 App 自身
7. 用户数据目录（文稿/桌面/下载/图片）默认禁止，除非规则显式 `allowedInUserData`
8. 路径必须仍匹配声称的规则模式（读规则就能知道它最多能删什么）
9. 占用检测：可执行文件在该路径下的进程、归属 App 正在运行
10. 是否需要 root

**引擎每项跑两遍**：扫描时一遍渲染界面，移入隔离区前逐项再跑一遍。第二遍是必需的——两次之间可能有构建启动、App 打开、路径被换成符号链接。

`allowedInUserData` 只有 16 条规则打开：6 条构建产物（node_modules / Pods / .build / target / .venv / .next），以及大文件和重复文件在 5 个用户目录（下载 / 文稿 / 桌面 / 影片 / 图片）下各自的一条。有测试锁死这份清单。特权规则 7 条，全部位于测试显式列出的系统根下。

### 隔离区

删除一律是「移动到隔离区」，N 天后（默认 7 天，可配置）才真删。

- 跨卷 `moveItem` 失败会回落到 copy + remove
- 还原时若原位置已有同名文件，**中止而不是覆盖**
- 每条记录保留当时的规则 rationale 和模型解释，一周后还能回答「这为什么被删了」
- 清扫在每次启动时执行，不依赖用户打开某个界面

---

## AI 层

三种后端，用户可切：

| 模式 | 后端 | 数据流向 |
|---|---|---|
| `offline`（默认） | `HeuristicAdvisor` 内置模式表 | 不出进程 |
| `local` | `LocalModelAdvisor` → 127.0.0.1 上的小模型 | 不出本机（非回环地址直接拒绝） |
| `cloud` | `CloudAdvisor` → Anthropic Messages API | 仅脱敏元数据 |

`CompositeAdvisor` 保证：任何后端失败或超时都回落到内置规则表，每一项都有解释；模型返回的、不在本批次里的 id 一律丢弃。

**卸载残留溯源**是 AI 真正有增量的地方。`AppResidueScanner` 只做确定性的那一半（精确匹配 / 厂商前缀匹配），把 `.vendorInstalled` 和 `.none` 交给模型。`EvidenceCollector` 提供的证据是：文件名 + 目录列表 + plist 顶层键名与身份值 + 文本文件头 384 字节，全部脱敏后传入。

---

## 技术栈

- **SwiftUI + AppKit 混合**，macOS 14+
- **不上 App Store**：沙盒进程拿不到完整磁盘访问权限，`~/Library` 下几乎什么都看不到。Developer ID 独立分发 + 公证。
- **提权**：`SMAppService` 注册的特权 Helper。主进程绝不以 root 运行。
- **XPC 双向校验**：`NSXPCListener.setConnectionCodeSigningRequirement` + `NSXPCConnection.setCodeSigningRequirement`，不碰 `auditToken` 私有 API。要求串从**运行中二进制自己的 team identifier** 推导——签名不一致的构建互相连不上；拿不到 team id 时 Helper 直接退出而不是降级放行。
- **Helper 不信任客户端**：同一份 `RuleCatalog` 在 root 侧再跑一遍，且只接受能被 `requiresPrivilege` 规则匹配的路径；`purge` 只允许删隔离区内部的路径。
- **玻璃 UI**：macOS 26+ 用真正的 Liquid Glass，以下回落到 `Material`，部署目标仍是 14。

---

## 目录结构

```
Sources/
  MacVitalKit/          静态库，App 与 Helper 共用（安全核心，不依赖 SwiftUI）
    Model/              ScanItem / RuleDecision / AIAssessment / Finding
    Rules/              PathPattern, ProtectedPaths, SIPGuard,
                        RunningProcessIndex, RuleCatalog, RuleEngine
    Scanners/           5 个扫描器 + ScanEngine
    Uninstall/          AppUninstallPlanner
    Startup/            LoginItemScanner
    AI/                 AIAdvisor 协议、三种实现、证据采集、提示词
    Quarantine/         QuarantineStore, CleanupCoordinator
    XPC/                HelperProtocol, HelperClient, CodeRequirement
    Util/               路径脱敏、格式化、钥匙串、日志
  MacVital/             SwiftUI App
    Views/Pages/        八个页面
    Annotate/           标注对象模型、画布、屏幕画笔、白板
    Screenshot/         截图、录屏、局域网直播
  MacVitalHelper/       特权助手（root，无 entitlement）
Tests/MacVitalKitTests/ 215 个测试，全部针对安全核心
Tools/MakeAppIcon.swift 图标生成脚本（图标可复现）
```

约 15,200 行 Swift。

---

## 构建

需要 macOS 14+、Xcode 15+、[XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```bash
brew install xcodegen
```

```bash
make test      # 单元测试（独立 scheme，不会构建 App）
make build     # 编译（ad-hoc 签名，默认 Release）
make install   # 装到 /Applications；装之前先校验构建产物的签名，不合格就中止
make run       # 编译并启动
make icon      # 从脚本重新生成 App 图标
```

`make build` 用 **ad-hoc 签名**，不需要任何证书就能跑起来。代价是这样出来的 App **用不了特权助手**——Helper 拿不到 team identifier 会主动退出，这是设计如此。

签名方式直接决定权限能不能拿到、助手能不能用，三种姿势的取舍见 **[docs/SIGNING.md](docs/SIGNING.md)**：

| | `make build` | `make build-selfsigned` | `make build-signed` |
|---|---|---|---|
| 需要证书 | 否 | 自签名（钥匙串自建） | Developer ID（$99/年） |
| TCC 授权跨重编译保留 | ❌ | ✅ | ✅ |
| 特权助手可用 | ❌ | ❌ | ✅ |

### 首次运行

在「系统设置 → 隐私与安全性 → 完整磁盘访问权限」里加入 MacVital，然后**重启 App**。没有这个权限，`~/Library` 下绝大部分内容不可见，扫描结果会严重偏少。App 内有引导横幅。

重启不是保守建议，是必须的：macOS 在**进程启动时**绑定这个权限，正在运行的进程不会感知到你刚打开的开关。所以横幅上的「重新检测」在授权后仍然显示未获得是正常的——它报的是当前进程的真实状态。

> **ad-hoc 构建每次重装后都要重新授权一次。** requirement 基于 cdhash，重新编译就变。`make install` 只在确实是 ad-hoc 签名时才提醒你重新授权——用证书签过名就不会再刷这段话。原理和步骤见 [docs/SIGNING.md](docs/SIGNING.md)。

> **权限勾了却依然没用，先查有没有第二份 MacVital.app。** TCC 的授权绑定在 designated requirement 上，而 macOS 会把 `com.macvital.MacVital` 解析到机器上*某一份*同名包再去校验。如果构建目录里还躺着一份签名不同（或签名已损坏）的副本，系统可能拿它来校验，结果就是设置里开关是开的、App 却一直说没权限——两边都没说谎。`make install` 装完会自动扫描并列出 requirement 不一致的副本；手动查：
>
> ```bash
> mdfind "kMDItemCFBundleIdentifier == 'com.macvital.MacVital'"
> ```

装完随时可以自查包签名是否有效（这一步能省掉一整场调试）：

```bash
make verify-signing
```

截图、录屏和直播会另外请求「屏幕录制」权限；直播还会触发防火墙的接入连接询问。

### 调试 Helper

```bash
make helper-log
```

---

## 状态

已实现：垃圾清理、卸载应用、开机启动项、截图与标注、屏幕画笔、录屏、局域网直播、白板、菜单栏网速、深色模式、三种 AI 后端。

**未在签名构建下验证**（需要 Developer ID 证书 + 真机）：

- `SMAppService.daemon` 注册后 `MachServices` 能否被 `NSXPCConnection(machServiceName:options:.privileged)` 连上
- `setConnectionCodeSigningRequirement` 的要求串在真实签名下是否通过
- 特权路径整条链路：`moveToQuarantine` → `chownToOwner` → 还原 / 清除

已知不做的事：

- **推流到 Twitch / YouTube / B 站**。那需要 RTMP，macOS 没有对应框架；手写协议是一千多行且无法在没有推流码的情况下测试。直播功能是局域网 MJPEG，见 [LiveBroadcaster](Sources/MacVital/Screenshot/LiveBroadcaster.swift) 的文件头注释。
- **通过 `SMAppService` 注册的现代登录项**。它们存在系统数据库里而不是 plist，移文件动不了，需要另一套 API。

---

## 许可

[MIT](LICENSE)。

这是一个会移动用户文件的工具，MIT 的免责条款（"AS IS", without warranty）请当真读一遍——真正的安全保证在代码和 [docs/SAFETY.md](docs/SAFETY.md) 里，不在许可证里。
