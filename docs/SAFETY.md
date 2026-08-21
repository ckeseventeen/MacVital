# 安全模型

这份文档写给两类人：想给这个项目加功能的人，和想审计它到底会不会删错东西的人。

前提：**这是一个会永久移动用户文件的工具**。它的价值不在于删得多，而在于它删的每一样东西都能被解释、被追溯、被撤销。下面每一条约束都是为这句话服务的，改动它们之前请先读完这一页。

---

## 一、准入是白名单，不是黑名单

全部 85 条规则集中在 [`RuleCatalog.swift`](../Sources/MacVitalKit/Rules/RuleCatalog.swift) 一个文件。

**不在这份清单里的路径，系统里没有任何代码路径能把它变成删除目标。** 扫描器提不出来（`ScanItem` 必须携带一个 `ruleID`），用户点不中（UI 只渲染扫描器产出的项），模型也够不着（`AIAdvisor` 协议没有返回准入的方法）。

规则本身**不携带准入**。一条规则说的是「这种形状的路径是一类已知的、有名字的、可重建的产物」，具体这一个实例此刻能不能删，由 `RuleEngine` 叠加 SIP 检查、保护路径检查、占用检查和权限检查之后决定。**加一条规则永远不可能绕过任何一道闸门。**

审计一条规则时，看 `pattern` 就够了：它是这条规则能触及的路径的**完整上界**。

---

## 二、十道闸门，只降不升

[`RuleEngine.evaluate`](../Sources/MacVitalKit/Rules/RuleEngine.swift) 是唯一的准入函数。

| # | 检查 | 存在的理由 |
|---|---|---|
| 1 | 规则必须存在 | 扫描器产出未知 ruleID 是 bug，而 bug 的安全响应是拒绝 |
| 2 | 结构性拒绝清单（**按声称路径**） | 不依赖文件系统状态。受保护路径的答案永远是「受保护」，不会因为文件恰好不存在而变成「已删除」 |
| 3 | realpath 解析；是符号链接直接拒绝 | 绝不跟随。一条匹配 `~/Library/Caches/foo` 的规则不该授权删除 foo 指向的东西 |
| 4 | 拒绝清单（**按解析后路径**） | 符号链接不能把声称路径洗成合法路径 |
| 5 | `st_flags`：`SF_RESTRICTED` / `UF_IMMUTABLE` / `UF_DATAVAULT` | 问文件系统本身。SIP 覆盖范围随系统版本变化，硬编码清单会过期 |
| 6 | 自我保护前缀 | 隔离区绝不能被自己清理掉 |
| 7 | 敏感用户目录 | 文稿/桌面/下载/图片默认禁止，除非规则显式 `allowedInUserData` |
| 8 | 路径必须仍匹配声称的规则模式 | 这道检查是「读规则就能知道它最多能删什么」成立的原因 |
| 9 | 占用检测 | 删正在被编译器写入的目录会毁掉构建；删运行中 App 的容器会丢它的状态 |
| 10 | 是否需要 root | 决定走不走特权助手。**只有 `requiresPrivilege` 规则能走**——Helper 也只认这些规则，把别的路径递过去必然被它拒绝 |
| 10b | 当前用户能否 unlink | 非特权规则的路径若连父目录都不可写，直接拒绝（`notRemovableByUser`）。root 在这里不是答案，说实话比给一个必然失败的按钮好 |

**每道检查只能降级，没有任何一道能把 deny 变回 allow。**

第 10 条的两侧必须一致：`RuleEngine` 判定「走特权助手」的条件，和 `HelperService.validatedRemovalDestination` 接受路径的条件，是同一个 `requiresPrivilege` 谓词。两边一旦分叉，用户看到的就是一个每次都失败的按钮——`PrivilegeRoutingTests` 锁住这一点。

### 跑两遍

引擎在扫描时跑一遍（渲染界面），在移入隔离区**前逐项再跑一遍**（[`CleanupCoordinator.execute`](../Sources/MacVitalKit/Quarantine/CleanupCoordinator.swift)）。

第一遍是快照。两遍之间用户可能启动了构建、打开了 App，或者某个路径被换成了符号链接。第二遍不是冗余，是必需。

---

## 三、绝对拒绝清单的两个例外

[`ProtectedPaths`](../Sources/MacVitalKit/Rules/ProtectedPaths.swift) 的 `hardDeny` 层原本是无条件的。目前它有且只有**两个**记录在案的例外。**新增第三个之前请先确认没有别的做法。**

### 例外 1：`/Applications/*.app`

引擎拒绝一切浅于三层的路径（防的是 `/Library/Foo` 这类删除）。而 App 包天生就是两层。

口子的边界：

- 父目录必须**正好是** `/Applications`
- 名字必须以 `.app` 结尾

它本身不授予任何权限：`/Applications/Safari.app` 和 `/Applications/Utilities` 仍被前缀清单拦下，`/System` 下的包根本走不到这里。

测试：`ApplicationBundleCarveOutTests`。

### 例外 2：`/private/var/db/receipts/*`

`/private/var/db` 在拒绝清单里，因为它装着 `dslocal`（本地账户数据库）、TCC 库、配置描述文件——丢任何一个都不可恢复。

安装回执是它下面的一个子目录，内容是每个安装包的 `.bom` + `.plist`，删了只是让 `pkgutil --pkgs` 不再列出该包，**不影响任何已安装的软件**。

口子的边界（[`ProtectedPaths.isInstallerReceipt`](../Sources/MacVitalKit/Rules/ProtectedPaths.swift)）：

- 父目录必须**正好是** `/private/var/db/receipts`
- 目录本身**不**豁免
- 下一层嵌套**不**豁免
- `receiptsBackup` 这类同前缀兄弟**不**豁免

测试：`InstallerReceiptCarveOutTests`，其中显式断言 `dslocal/nodes/Default/users/root.plist` 仍然被拒。

> **这个例外的收益很低**（每个包几 KB）。如果你在评估要不要保留它，撤掉它是安全的：删掉 `uninstall.installerReceipt` 规则、`isInstallerReceipt` 及其在 `isHardDenied` 里的调用，以及对应测试即可，其余功能不受影响。

---

## 四、特权边界

主进程**绝不以 root 运行**。需要 root 的操作走 `SMAppService` 注册的 Helper。

### Helper 假设客户端是敌对的

- 同一份 `RuleCatalog` 在 root 侧**再跑一遍**
- 只接受能被 `requiresPrivilege` 规则匹配的路径（目前 7 条，全在测试显式列出的系统根下）
- `purge` 只允许删隔离区内部的路径
- 隔离区路径必须形如 `/Users/<name>/Library/Application Support/MacVital/Quarantine`，且**属主不能是 root**（root 拥有的隔离区意味着有人伪造了它）
- 归还属主用 `lchown` 而不是 `chown`——被移动的树来自特权目录且内容非我方编写，`chown` 会跟随符号链接，等于把系统上任意文件的属主交给非特权用户

### 连接认证

用 macOS 13+ 的 `setConnectionCodeSigningRequirement`，不碰 `auditToken` 私有 API。

要求串从**运行中二进制自己的 team identifier** 推导。签名不一致的构建互相连不上。拿不到 team id 时 **Helper 直接 `exit(EXIT_FAILURE)`，而不是降级放行**——未签名构建下没有任何办法认证调用方，那就不提供服务。

---

## 五、删除不是删除

所有移除都是「移进隔离区」，默认 7 天后才真删。

- 跨卷 `moveItem` 失败回落到 copy + remove
- 还原时若原位置已有同名文件，**中止而不是覆盖**——静默覆盖正是隔离区要防的那类事故
- 每条记录保留当时的规则 rationale 和模型解释
- 清扫在每次启动执行，不依赖用户打开某个界面

「停用开机启动项」用的也是这条路径：移走 plist 而不是 `launchctl unload`。运行时状态难撤销也看不见，移文件对下次登录效果一样且完全可还原。

---

## 六、归因：错的方向不对称

判断一个文件属于哪个 App，两种错法的代价差着数量级：

- **少认领**：漏掉一条清理建议
- **多认领**：把在用 App 的数据当残留删掉

所以 [`InstalledAppIndex`](../Sources/MacVitalKit/Scanners/InstalledAppIndex.swift) 的匹配一律往「**还装着**」的方向倒。

这不是假想的风险。开发过程中实测发现，早期版本把 `~/Library/Application Support/Google`（742 MB，Chrome 的完整配置）和 `baidunetdisk`（517 MB）报成了「卸载残留」。三个原因叠加：

1. `Bundle` 读出的 `CFBundleName` 是**本地化**的——百度网盘在索引里叫「百度网盘」，目录叫 `baidunetdisk`
2. bundle id `com.baidu.BaiduNetdisk-mac` 里的连字符没归一化
3. `Application Support` 下的目录基本都是人类名字，而匹配只认 bundle id 和完全相等的 App 名

现在索引同时收录本地化显示名、**磁盘上的 .app 文件名**（非本地化）、bundle id 的各段词，归一化后做双向前缀匹配。回归测试锁死了这几个真实案例。

---

## 七、改动这套东西时

- **加规则**：改 `RuleCatalog`，写清楚 `pattern` 的上界。默认 `autoSelectable: false`。
- **加特权规则**：`RuleEngineTests.testPrivilegedRulesLiveOnlyInApprovedSystemRoots` 里有一份显式的系统根白名单，必须手动加进去——这是刻意的，特权规则不该跟着功能悄悄溜进来。
- **动 `allowedInUserData`**：有测试锁死这 8 条。扩大它必须是刻意的。
- **动拒绝清单**：见第三节。加第三个例外前先确认真的没有别的做法。
- **加 UI 颜色/样式**：放在 App 层。`MacVitalKit` 是安全核心，不依赖 SwiftUI，规则引擎不该有任何东西能依赖一个颜色。

测试跑 `make test`，72 个，全部针对安全核心。
