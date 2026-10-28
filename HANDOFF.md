# Claude 接手：网关认证/真实桌面切换仍不可用

**最新结论（2026-10-28）：用户在本机 1.12.1 实际切换后反馈“完全不可用”。未验收通过。不要将下面的自动化或隔离测试解释为真实桌面可用。**

本分支是用户要求上传的未完成工作快照，含路由动效和认证候选修复；不发布新 Release、不更新默认分支。公开基线：`31945f64fa9120a2c194feba75e77fa10109a922`。私人构建的受测版本1.12.1/build31；公开构建脚本0.4.0/build5仅为未发布候选编号，不能据此认定版本已发布。

## 用户目标与操作边界

多账号原生macOS菜单栏组件；借鉴Magpie设计的本机网关，使Codex新旧会话无需手动切号即可路由。保留官方provider和Fast能力。现阶段优先排查实际不可用，暂停动效发布。

- 不清理整个`.codex`、不删除账号或聊天记录、不重装恢复现场、不无差别终止任务。
- 当前可用会话应保持直连，测试使用另一个账号、独立CODEX_HOME和独立端口。是否当前仍直连须实时只读核验，不能依赖此前记录。
- 涉及重启当前Codex，要先保存诊断并说明中断影响。不要因隔离测试通过就直接开启生产路由。
- 不跳过本机鉴权、不仅凭账号ID放行、不接受任意Bearer。不要输出/上传token、密钥、完整登录文件、私人日志或截图。
- 用户已确认白屏属于网络问题；不要未经证据把白屏归因于401。
- 本次最新“直接切换”究竟是手动切换桌面账号、网关固定账号、开启路由，还是其他入口，尚未取得操作级证据；不要擅自确定其含义或断言新故障仍是相同401。

## 版本与目录差异

| 项目 | 私人构建 | 公开构建 |
|---|---|---|
| 数据目录 | `~/Library/Application Support/CodexAccountManager/` | `~/Library/Application Support/CodexAccountsPublic/` |
| 默认网关端口 | 18455 | 18456 |
| bundle ID | 私人构建身份 | `io.github.ruanjianjian.codex-accounts` |
| 初始账号/快捷键/监控 | 用户已有私人偏好 | 空账号、快捷键及监控默认关闭 |

两个版本不能同时接管默认Codex配置。不要复制私人数据目录到公开版来试。故障机器上官方应用实际为`/Applications/ChatGPT.app`，bundle ID `com.openai.codex`，版本26.1023.50603/build22391；其内置Codex CLI为0.165.0-alpha.1.2。接手时重新核实版本和运行进程。

## 已复现的旧401根因（不是最新故障的定论）

旧版错误：`401 Unauthorized: Invalid local gateway key.`，请求地址`http://127.0.0.1:18455/backend-api/codex/responses`，在转发OpenAI之前被本机网关拒绝。

只读比对发现：`desktop-switch/selection.json`历史记录指向槽A，默认桌面凭据实际上是已登记槽B；槽B桌面令牌与独立账号目录令牌不同，两者均未过期。`AppStore.updateGatewayPool()`旧逻辑按历史selection决定凭据来源，导致A被身份检查跳过、B读到另一份令牌。当前未暂停账号、没有双版本监听证据。

用旧二进制、真实本机凭据、按旧逻辑重建的池，在隔离端口复现完全一致的401。故障瞬间原pool已在此前关闭路由时被删除，未捕获历史失败请求的完整现场；不能证明每次故障的最初登录/刷新时序。诊断期间local.key未变，无证据支持本轮由密钥轮换引发。

## 此分支的候选修改

- `Sources/AccountManager/AppStore.swift`：按实际桌面账号匹配凭据，客户端身份列表与可路由池分开；启动前验证已登记桌面身份；处理本地鉴权失败事件。
- `Sources/AccountCore/GatewayConfiguration.swift`：新增身份数据结构、凭据选择函数；重新安装时检测密钥/端口变化并保持配置恢复能力。
- `Gateway/native_auth.go`：每请求读取固定路径的私有桌面凭据；要求当前用户所有、权限私有、无符号链接、有效期及账号声明一致。只对可信本机文件观察到的令牌保存SHA-256指纹/到期时间/账号绑定，最多256条；用于客户端缓存旧令牌和网关重启。不是JWT远程签名验证，不根据HTTP传来的JWT内容授予访问。
- `Gateway/main.go`：保留本机密钥或精确令牌鉴权；加入`--desktop-auth`、认证失败类别日志、请求事件关联。暂停或耗尽账号不因客户端鉴权重新加入候选池。
- 路由动效：`RoutingActivity.swift`、`RoutingActivityView.swift`、`DesktopWidget.swift`；原生Canvas路径/光点、并发计数、收起展开、降低动态效果支持，事件来自网关。动效模拟预览测过，真实交互未完整验收。

## 已测与未测

私人构建：Go14项race测试通过；Swift84项中83通过、1个原有可选fixture跳过。认证负向测试覆盖错误Bearer、错账号头、未登记身份、过期、符号链接/不安全权限。配置测试覆盖密钥/端口变化、重复安装、启停恢复及并发修改保护。

隔离真实官方app-server使用另一个账号、独立CODEX_HOME、端口19457：直连创建旧会话→经网关恢复旧会话→网关新会话→网关重启续聊→客户端重启续聊→恢复直连，共6轮completed且回复正确。4轮网关请求均有routing/completed/finished，无认证错误；provider=openai、serviceTier=priority。测试副本不含可用refresh_token，正式账号/主桌面auth和config前后未变。测试进程已退出。

**这个测试没有开第二个桌面GUI，没有点击真实“切换”入口，没有触发自然OAuth刷新，没有产生持久化encrypted_content，没有测试流中重启。它不能覆盖用户最新实际失败。** 模型参数保持priority也不能替代Fast按钮UI验收。

公开分支同步后的编译/测试结果见`docs/HANDOFF-VALIDATION.md`。可携带的隔离测试脚本为`scripts/diagnostics/isolated_codex_probe.py`，需要接手者显式提供自己的文件路径，不附带任何凭据。

## 优先排查线索（均非最新故障已确认根因）

1. 先确认用户实际使用入口和当前错误。检查18455/18456监听进程、真实生效配置、helper路径/版本；只比对凭据匹配结果，不输出内容。
2. `AppStore.verifySharedIdentity()`、`client()`等采集/手动切号路径仍依赖历史selection；网关的修复未统一这些路径。检查它们是否将旧槽误当当前桌面，或拒绝实际已登录账号。
3. `Gateway.candidates()`在会话绑定前过滤preferred；切固定账号时与旧会话原账号可能冲突。加密历史不能任意跨账号重放，应明确拒绝、清晰提示，不能降级安全边界。
4. 普通退出管家`stop(restore:false)`停网关但保留路由配置；只有关闭开关恢复配置。在客户端还指向本机时退出/升级会中断请求；当前没有热升级保证。
5. `GatewayController`丢弃helper stderr，仅ready表示监听成功，`gatewayReady`并非桌面端到端就绪。核对启动失败与配置安装失败在UI中的实际表现。
6. 网关只实现Responses/compact/models等部分路由；官方桌面的其他功能、客户端账户额度预检、WebSocket降级、工具相关调用不一定等价于短对话app-server探针。
7. 自然刷新、账户移除、账号池暂停与历史令牌指纹保留的整个生命周期还需真正验收。修复前未观察过的旧内存令牌不会仅因账号ID正确而获准。

## 本机已有证据位置（只读，不上传目录）

在故障机器的`~/DevData/Artifacts/`下：

- `20261028-gateway-auth-fix/REPORT.md`、`reproduction.json`、`live-regression.json`、`installed-state.json`、测试日志、前后源码patch。
- `20261028-codex-isolated-acceptance/REPORT.md`、`verification.json`、`status.json`、`run.py`、测试会话。
- `20261028-routing-motion/`：动效构建和模拟预览证据。

`private-snapshot/`、所有auth/pool/key/指纹/会话映射、浏览器数据均属敏感本机资料，不进Git。旧App回退副本仍保留；回退前确认管家已正常退出且不会影响当前请求，不双开。私人工作树保留未提交原始现场，公开分支只同步经过检查的源码与脱敏说明。
