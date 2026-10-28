# Codex Accounts · Public Beta

A local-first macOS menu-bar app for multiple Codex accounts. 原生 macOS 多账号额度组件。

**测试版 v0.1.0-beta.1** · macOS 14+ · 首发下载包仅 Apple Silicon · MIT

独立社区工具，与 OpenAI、X、DeepSeek 无隶属或背书关系。所有账号都由使用者自行登录；不附带账号、API Key、Cookie 或任何个人登录数据。

## 能做什么

- 无限数量的账号卡片：官方额度窗口、重置时间、banked reset 数量与到期信息。
- 近7天 token 柱状图，展开查看更长日期；缺失数据保留为未知，不补零。
- 菜单栏悬停呼出，移出/点击外部收起；可调整大小、置顶、选择两键快捷键。
- 各账号独立 Codex 登录目录，持久登录；支持 Chrome Profile 或账号专用浏览器窗口。
- 可选 Tibo X 监控：个人 X 登录后每分钟读取主页可见帖子，新重置相关帖触发所有账号官方额度查询。首次只建立基线，不重播历史帖，不使用 banked reset。

额度是服务端账号总额度，包含该账号在其他电脑上的使用，无需在其他电脑也装本工具。不能按设备拆分消耗，也不把百分比换算成 token。

## 安装下载版

1. 在 [Releases](https://github.com/ruanjianjian/codex-account-manager/releases) 下载 `Codex-Accounts-v0.1.0-beta.1-macos-arm64.zip` 和 `SHA256SUMS.txt`。在同一目录执行 `shasum -a 256 -c SHA256SUMS.txt` 核对文件。
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

需要完整 Xcode（Swift 6 工具链）、macOS 14+。测试 mock 还需要 Python 3。构建当前 Mac 架构；Intel 源码构建尚未验收，首发不提供 Intel 下载包。

```sh
git clone https://github.com/ruanjianjian/codex-account-manager.git
cd codex-account-manager
swift test
./scripts/build.sh
./scripts/install.sh
```

产物默认位于 `dist/Codex Accounts Beta.app`；缓存位于 `.build`。可设置 `PUBLIC_DIST_DIR` 指定产物目录。脚本拒绝覆盖现有构建和已安装的同名应用；更新时先退出公开版，将旧 **Codex Accounts Beta.app** 移到废纸篓，再安装新版，应用数据仍保留。

本工具不打包 Codex CLI，按顺序发现常见 npm、Codex/ChatGPT 应用及 Homebrew 安装位置。若提示未找到 CLI，请确认 `codex --version` 可用且位于 `/opt/homebrew/bin/codex` 或 `/usr/local/bin/codex`，或使用支持的应用内置路径。

## 初次使用与隔离

- 初次启动为空账号列表，默认关闭公告监控、通知、开机启动和全局快捷键；可在设置中启用。
- 公开版标识为 `io.github.ruanjianjian.codex-accounts`，数据独立保存在 `~/Library/Application Support/CodexAccountsPublic/`。
- 不自动导入其他应用的数据，不更改其他 Codex 客户端登录。WebKit 的 X 登录态和应用偏好也使用公开版独立身份。
- 若已有个人构建，可同时保留；不要给两者配置相同快捷键。不同 Codex 客户端同时发起 OAuth 可能争用 localhost 回调端口，请按次完成授权。
- 账号菜单可重新连接或移除连接。钥匙串可能要求首次访问授权；系统安全策略、更新或登录失效仍可能要求重新验证，不能保证永远不弹窗。

## X 监控与实验功能

设置 → 登录 / 查看个人 X → 用自己的邮箱/用户名登录 → 打开 Tibo 主页 → 测试并开启。登录成功后窗口可以关闭，后台每分钟检查；打开该窗口时暂停后台导航，避免打断输入。失败会退避，休眠/退出时停止，唤醒补查。

这是可见页面抓取，不是 X 推送接口。只覆盖主页已加载的本人帖子，可能漏掉回复、被折叠内容或断线期间的帖子；页面结构、限流、登录验证都可能导致失败。简短 reset 活动帖只作为查询额度的信号，不代表官方额度已经重置。不支持 Google/Apple 外部登录跳转。

未连接个人 X 时，可手动开启第三方公告源 `codexreset-news.com`，约5分钟检查一次，可能延迟。首次启动不会自动请求它。

DeepSeek 手动测试入口是实验功能，**目前未验证能成功抓取 X**，不是默认监控依赖。仅使用者手动提交 Key 后调用 `api.deepseek.com`，可能产生供应商费用；Key 仅保存在本次进程内存，退出即清除。

## 隐私、安全与限制

详见 [PRIVACY.md](PRIVACY.md)、[SECURITY.md](SECURITY.md) 和 [测试版验证记录](docs/VALIDATION.md)。请勿在 Issue 上传账户目录、Cookie、Key、OAuth 回调链接或未经脱敏的截图。

账号/额度读取使用官方 Codex app-server 的实验协议，不保证所有套餐、CLI 版本或未来接口兼容。没有模型推理请求，不自动切换你正在使用的 Codex 账号，不代用重置券。实际额度以官方返回为准。

## 卸载

先在公开版设置中关闭「登录 Mac 时启动」，按需从账号菜单移除账号连接，然后退出并将 **Codex Accounts Beta.app** 移到废纸篓。删除应用本身不会删除登录和缓存。如需清除，使用设置里的「打开本机数据目录」核对公开版目录后手动删除；X 网站数据由系统 WebKit 存储，应用重装后可能仍保留。不要删除其他客户端的目录或钥匙串条目。

## 贡献

欢迎通过 Issue 提交已脱敏的系统版本、CLI版本、复现步骤与错误类别。PR 请运行 `swift test` 与 `./scripts/build.sh`，不要提交真实账号信息。发布前运行 `gitleaks git . --redact` 和 `gitleaks dir . --redact`。

供发布者将来选择使用的签名、公证与票据校验流程见 [NOTARIZATION.md](docs/NOTARIZATION.md)；它不是安装步骤。当前测试包仍以 Release 标注的签名状态为准。

[MIT License](LICENSE)
