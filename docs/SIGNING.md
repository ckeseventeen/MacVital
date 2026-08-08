# 签名

这一页解释三种签名姿势各自能换来什么。**它不是可选的配置细节**——签名方式直接决定 App 能不能拿到完整磁盘访问权限、特权助手能不能工作。

## 三种姿势

| | `make build`（ad-hoc） | 自签名证书 | Developer ID |
|---|---|---|---|
| 本机能跑 | ✅ | ✅ | ✅ |
| 有 designated requirement | ✅ | ✅ | ✅ |
| **TCC 授权能跨重新编译保留** | ❌ | ✅ | ✅ |
| **特权助手（提权清理）可用** | ❌ | ❌ | ✅ |
| 能分发给别人 | ❌ | ❌ | ✅（+ 公证） |
| 需要 Apple 开发者账号 | 否 | 否 | 是（$99/年） |

## 为什么 ad-hoc 每次编译都要重新授权

TCC 把权限授予记在 App 的 **designated requirement** 上。ad-hoc 签名的 requirement 长这样：

```
designated => cdhash H"b9920cd9…" or cdhash H"01619073…"
```

它锁的是可执行文件的哈希，而**每次重新编译哈希都会变**，旧授权随即失效——但系统设置里的开关仍然显示是打开的。

用证书签名时 requirement 变成基于证书主体的，跟哈希无关，重新编译也不受影响。

> ### 曾经踩过的坑：签名"看起来有"但其实没有
>
> Makefile 里原本是 `CODE_SIGNING_ALLOWED=NO`，Xcode 会**完全跳过包签名**。主可执行文件仍带着链接器给的 ad-hoc 签名，所以 `codesign -dv` 会正常打印 `Signature=adhoc` 和 CDHash，看上去毫无问题——但 `.app` 下没有 `_CodeSignature`，整个包**没有任何 designated requirement**。
>
> 后果：TCC 没有东西可以记。App 能被加进完整磁盘访问权限、开关能打开，却永远匹配不上运行中的进程，**永远处于未授权状态，重启和重新添加都修不好**。
>
> 一条命令就能区分这两种情况：
>
> ```bash
> codesign --verify --deep --strict --verbose=2 /Applications/MacVital.app
> ```
>
> `code object is not signed at all` = 踩了这个坑。正常应该是 `valid on disk` + `satisfies its Designated Requirement`。

---

## 配自签名证书

只解决 TCC 反复失效的问题，**不能让特权助手工作**（原因见下一节）。

1. 打开「钥匙串访问」
2. 菜单栏 →「钥匙串访问」→「证书助理」→「创建证书…」
3. 填：
   - 名称：`MacVital Local`
   - 身份类型：**自签名根证书**
   - 证书类型：**代码签名**
   - 勾上「让我覆盖这些默认值」
4. 一路下一步，钥匙串选**登录**
5. 确认能被找到：

```bash
security find-identity -v -p codesigning
```

应该能看到 `MacVital Local`。然后：

```bash
make build-selfsigned
make install
```

`IDENTITY` 可以覆盖：`make build-selfsigned IDENTITY="你的证书名"`。

装完仍需在完整磁盘访问权限里**移除旧条目再重新添加**一次——这是从 ad-hoc 换到证书的一次性代价，之后重新编译就不用再动了。

---

## 为什么自签名证书救不了特权助手

App 和助手之间的 XPC 连接用 `setConnectionCodeSigningRequirement` 双向校验，要求串从**运行中二进制自己的 team identifier** 推导（`CodeRequirement.teamIdentifier()`）。

**team identifier 只存在于 Apple 签发的证书里**（在 `certificate leaf[subject.OU]` 字段）。自签名证书没有这个字段，`teamIdentifier()` 返回 `nil`，助手会主动 `exit(EXIT_FAILURE)` 而不是降级放行——因为没有 team id 就没有任何办法认证调用方，那就不提供服务。这是刻意的，见 [SAFETY.md](SAFETY.md) 第四节。

所以需要 root 的那 5 条规则（`/Library` 下的系统级残留）在非 Developer ID 构建下**不可用**。其余全部功能不受影响。

---

## 配 Developer ID

需要 Apple Developer Program 会员资格。拿到证书后改**两个地方，且必须一致**：

| 文件 | 位置 |
|---|---|
| `Config/Shared.xcconfig` | `MACVITAL_TEAM_ID = ABCDE12345` |
| `Sources/MacVitalHelper/Info.plist` | `SMAuthorizedClients` 里的 `certificate leaf[subject.OU] = "ABCDE12345"` |

两处不一致的表现是助手拒绝每一个连接，而且不会有明显报错。`make build-signed` 会在编译前检查这两处是否都已改掉、且彼此相同，不通过会直接失败。

```bash
make build-signed
make archive        # 供 notarytool 公证
```
