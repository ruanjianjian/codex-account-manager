# Codex Accounts · Public Beta

A local-first macOS menu-bar app for multiple Codex accounts. 原生 macOS 多账号额度组件。

**测试版 v0.3.1-beta.1** · macOS 14+ · 首发下载包仅 Apple Silicon · MIT

独立社区工具，与 OpenAI、X、DeepSeek 无隶属或背书关系。所有账号都由使用者自行登录；不附带账号、API Key、Cookie 或任何个人登录数据。

## 能做什么

- 无限数量的账号卡片：官方额度窗口、重置时间、banked reset 数量与到期信息。
- 近7天 token 柱状图，展开查看更长日期；缺失数据保留为未知，不补零。
- 菜单栏悬停呼出，移出/点击外部收起；可调整大小、置顶、选择两键快捷键。
- 各账号独立 Codex 登录目录，持久登录；支持 Chrome Profile 或账号专用浏览器窗口。
- 可选 Tibo X 监控：个人 X 登录后每分钟读取主页可见帖子，新重置相关帖触发所有账号官方额度查询。首次只建立基线，不重播历史帖，不使用 banked reset。

额度是服务端账号总额度，包含该账号在其他电脑上的使用，无需在其他电脑也装本工具。不能按设备拆分消耗，也不把百分比换算成 token。

## v0.3.0 新增：本机自动账号路由（实验）

1. 先连接自己的账号，在设置里选择本地文件凭据模式。
2. 设置 → **自动账号路由**。开启后保存原 Codex 配置，保留官方 provider 和 Fast 设置，只把推理地址指向本机网关。
3. 结束手头任务，重启 Codex 后，**原有官方会话和新会话**都可进入网关。之后请求由网关选择账号，菜单栏组件显示最近承接请求的账号；无需为每个请求切换桌面登录。
4. 默认保持会话使用同一账号，新会话优先选择较快重置的可用账号。可在设置中固定账号，也可点击卡片的账号名称选择。仅输出开始前的可重试失败会尝试备用账号。
5. 关闭开关会恢复原 provider，保留期间对其他设置的修改；如网关配置项本身被其他程序改动，会拒绝覆盖并保留备份。关闭后同样重启 Codex。v0.3.0 创建的自定义 provider 会话仍需网关开启才能继续。

**使用期间保持管家运行。** 私有版本与公开版不能同时接管同一个默认 Codex 配置；先关闭另一版本的路由。

这版借鉴 Magpie 的账号池、会话固定和失败接替设计，使用独立实现的 Go 辅助进程（压缩协议依赖 klauspost/compress），并未复制其源码或完整兼容层。真实官方 CLI 的模型回复与终端工具调用已验证；官方 CLI 已验证直连创建会话后，经网关续聊能保留历史并执行工具。默认 Codex 桌面重启后的旧会话和 Fast 按钮显示仍待验收，先按实验功能使用。已输出内容/工具调用不会自动重放；加密历史及压缩状态依赖原账号，不能任意跨账号续接，会话账号绑定会在本机保存，网关重启后继续使用。原账号额度不足或客户端在发请求前拦截时，仍会报错；不能承诺带加密历史的旧会话任意跨账号接替。原生云端/远程功能尚未完整验收。

网关只监听本机，使用独立随机密钥；只导出短期 access token，沿用原采集进程管理 OAuth 刷新。账号认证文件保持原样，不新增钥匙串访问。网关凭据及配置备份位于数据目录 `gateway/`，禁止上传。详见 [网关说明](Gateway/README.md) 与 [验证记录](docs/VALIDATION.md)。

## v0.2.0 新增：切换桌面账号与文件凭据模式

- 点击已连接账号的名称 → 确认“切换并重启”。先结束正在运行的任务；Codex 会短暂退出再打开。沿用默认项目和会话目录，不复制或搬迁工作区。
- 当前适配 Codex 桌面 `26.1021.31345`、`26.1023.50603` 和默认 `~/.codex` 文件登录模式；其他版本或登录存储配置会拒绝操作。独立终端、机器人或其他应用的 Codex 进程仍在运行时也会阻止切换，不强杀进程。
- 设置 → 登录存储 → **改用本地文件存储…**：先自行连接账号，再阅读并确认迁移。账号目录权限700、文件600；**文件本身不加密，同一macOS用户下的程序可能读取**，不再享有钥匙串逐应用授权。原钥匙串记录保留。旧条目可能分别要求授权，不能保证迁移只输入一次密码。
- 文件模式启用后，管家的采集、切换和回退改读写本机文件，避免此次跨签名钥匙串反复授权问题。仍可能需要上游重新登录或2FA，不承诺所有系统弹窗永不出现。
- 继续使用钥匙串时，访问失败或查询超时会暂停该账号自动重试；处理后从该账号菜单点“刷新”恢复。
- 当前用于桌面的账号不能直接重新连接或移除；请先切到其他账号。迁移为单向入口，暂不提供一键迁回钥匙串。

## 从旧测试版升级

退出旧的 **Codex Accounts Beta.app**，将旧应用移到废纸篓，再放入新版。**不要删除 `CodexAccountsPublic` 数据目录**，已连接账号和偏好会保留。升级不会自动迁移凭据；需到设置主动选择。私人构建使用独立目录，不会自动导入。

## 安装下载版

1. 在 [Releases](https://github.com/ruanjianjian/codex-account-manager/releases) 下载 `Codex-Accounts-v0.3.1-beta.1-macos-arm64.zip` 和 `SHA256SUMS.txt`。在同一目录执行 `shasum -a 256 -c SHA256SUMS.txt` 核对文件。
2. 解压，将 **Codex Accounts Beta.app** 拖入 `~/Applications`。若没有这个文件夹，可自己新建。
3. 安装 [Google Chrome](https://www.google.com/chrome/) 到 `/Applications`，并安装官方 [Codex CLI](https://github.com/openai/codex)。本版开发验证使用 CLI 0.154.0；旧版可能不支持 token 活动或 banked reset 字段，缺失时显示未知。
4. 双击打开应用；若 macOS 拦截，请按下方「首次打开：手动放行」操作。启动后从菜单栏进入，点击右上角 `+`，自行完成 Codex 授权和必要的2FA。

### 首次打开：手动放行

当前测试版暂不进行 Apple 公证，下载包仅作 ad-hoc 签名，**未经 Apple Developer ID 签名或公证**。下载和使用本工具不需要购买 Apple Developer 会员。

确认下载来自本仓库的 Release 且上面的 SHA-256 校验通过后，如遇到「无法验证开发者」或「Apple 无法检查是否包含恶意软件」提示：

1. 先双击 **Codex Accounts Beta.app** 尝试打开；出现拦截提示时关闭提示，保留应用。
2. 打开 Mac 的 **系统设置 → 隐私与安全性**，向下滚动到「安全性」。
3. 找到针对 **Codex Accounts Beta** 的拦截提示，点 **「仍要打开」**。
4. 按系统提示验证身份，并在再次出现的确认框中点 **「打开」**。

系统会记住对这个 App 的允许，后续通常可直接双击打开；更新版本后可能需要再次确认。此操作只针对这个 App，**无需关闭 Gatekeeper，也无需执行解除安全限制的终端命令**。步骤依据 [Apple 官方说明：在 Mac 上安全地打开 App](https://support.apple.com/zh-cn/102445)；不同 macOS 版本的文案可能略有差异。

若没有「仍要打开」，先确认已尝试打开应用；受公司或学校管理的 Mac 可能不允许自行放行。若提示「将损坏你的电脑」或「App 已损坏」，请勿把它当作普通的未公证提示，重新下载并核对校验值，仍有问题可提交已脱敏的 Issue。若不希望放行未公证下载，可从源码自行构建。

## 从源码构建

需要完整 Xcode（Swift 6 工具链）、Go 1.26.8+、macOS 14+。测试 mock 还需要 Python 3。构建当前 Mac 架构；Intel 源码构建尚未验收，首发不提供 Intel 下载包。

```sh
git clone https://github.com/ruanjianjian/codex-account-manager.git
cd codex-account-manager
swift test
(cd Gateway && go test -race ./...)
./scripts/build.sh
./scripts/install.sh
```

产物默认位于 `dist/Codex Accounts Beta.app`；缓存位于 `.build`。可设置 `PUBLIC_DIST_DIR` 指定产物目录。脚本拒绝覆盖现有构建和已安装的同名应用；更新时先退出公开版，将旧 **Codex Accounts Beta.app** 移到废纸篓，再安装新版，应用数据仍保留。

本工具不打包 Codex CLI，按顺序发现常见 npm、Codex/ChatGPT 应用及 Homebrew 安装位置。若提示未找到 CLI，请确认 `codex --version` 可用且位于 `/opt/homebrew/bin/codex` 或 `/usr/local/bin/codex`，或使用支持的应用内置路径。

## 初次使用与隔离

- 初次启动为空账号列表，默认关闭公告监控、通知、开机启动和全局快捷键；可在设置中启用。
- 公开版标识为 `io.github.ruanjianjian.codex-accounts`，数据独立保存在 `~/Library/Application Support/CodexAccountsPublic/`。
- 不自动导入其他应用的数据。手动切号会更改默认 Codex 桌面登录；开启自动路由会修改默认 Codex 的 provider 配置，但不修改登录文件。WebKit 的 X 登录态和应用偏好也使用公开版独立身份。
- 若已有个人构建，可同时保留；不要给两者配置相同快捷键。不同 Codex 客户端同时发起 OAuth 可能争用 localhost 回调端口，请按次完成授权。
- 账号菜单可重新连接或移除连接。钥匙串可能要求首次访问授权；系统安全策略、更新或登录失效仍可能要求重新验证，不能保证永远不弹窗。

## X 监控与实验功能

设置 → 登录 / 查看个人 X → 用自己的邮箱/用户名登录 → 打开 Tibo 主页 → 测试并开启。登录成功后窗口可以关闭，后台每分钟检查；打开该窗口时暂停后台导航，避免打断输入。失败会退避，休眠/退出时停止，唤醒补查。

这是可见页面抓取，不是 X 推送接口。只覆盖主页已加载的本人帖子，可能漏掉回复、被折叠内容或断线期间的帖子；页面结构、限流、登录验证都可能导致失败。简短 reset 活动帖只作为查询额度的信号，不代表官方额度已经重置。不支持 Google/Apple 外部登录跳转。

未连接个人 X 时，可手动开启第三方公告源 `codexreset-news.com`，约5分钟检查一次，可能延迟。首次启动不会自动请求它。

DeepSeek 手动测试入口是实验功能，**目前未验证能成功抓取 X**，不是默认监控依赖。仅使用者手动提交 Key 后调用 `api.deepseek.com`，可能产生供应商费用；Key 仅保存在本次进程内存，退出即清除。

## 隐私、安全与限制

详见 [PRIVACY.md](PRIVACY.md)、[SECURITY.md](SECURITY.md) 和 [测试版验证记录](docs/VALIDATION.md)。请勿在 Issue 上传账户目录、Cookie、Key、OAuth 回调链接或未经脱敏的截图。

账号/额度读取使用官方 Codex app-server 的实验协议，不保证所有套餐、CLI 版本或未来接口兼容。额度查询本身不发起模型推理，也不代用重置券。开启路由后，模型请求会自动选择账号；关闭路由时，主动切号仍会重启默认 Codex 桌面。实际额度以官方返回为准。

## 卸载

先在公开版设置中关闭「自动账号路由」并重启 Codex，再关闭「登录 Mac 时启动」，按需从账号菜单移除账号连接，然后退出并将 **Codex Accounts Beta.app** 移到废纸篓。删除应用本身不会删除登录和缓存。如需清除，使用设置里的「打开本机数据目录」核对公开版目录后手动删除；X 网站数据由系统 WebKit 存储，应用重装后可能仍保留。不要删除其他客户端的目录或钥匙串条目。

## 致谢与设计参考

感谢 [yetone](https://github.com/yetone) 的开源项目 [Magpie](https://github.com/yetone/magpie)。本机网关与多账号自动路由借鉴了它的账号池、会话固定、输出前失败接替设计。

当前网关为独立实现，没有复制或打包 Magpie 源码，第三方压缩库许可见 Gateway/THIRD-PARTY-NOTICES.txt；仅实现本项目需要的 Codex HTTP/SSE 路由，不能视为完整的 Magpie 移植。设计调研基于 [6e080ca](https://github.com/yetone/magpie/tree/6e080ca0440ebe8d75b8eedd5bc78dd508542bed)。Magpie 使用 [MIT 许可证](https://github.com/yetone/magpie/blob/6e080ca0440ebe8d75b8eedd5bc78dd508542bed/LICENSE)，本项目独立开发与维护。

## 贡献

欢迎通过 Issue 提交已脱敏的系统版本、CLI版本、复现步骤与错误类别。PR 请运行 `swift test` 与 `./scripts/build.sh`，不要提交真实账号信息。发布前运行 `gitleaks git . --redact` 和 `gitleaks dir . --redact`。

供发布者将来选择使用的签名、公证与票据校验流程见 [NOTARIZATION.md](docs/NOTARIZATION.md)；它不是安装步骤。当前测试包仍以 Release 标注的签名状态为准。

[MIT License](LICENSE)
