# Tibot

**交给 agent 安装**：把下面这句话发给 Claude Code、Codex 等 agent，它会自己装好；已经装过的会更新到最新版，账号和登录都保留。

```text
请帮我在这台 Mac 上安装或更新 Tibot（开源的 Codex 多账号菜单栏工具，https://github.com/ruanjianjian/codex-account-manager）：
你自己在终端运行 curl -fsSL https://raw.githubusercontent.com/ruanjianjian/codex-account-manager/main/scripts/get.sh | bash（可以先读一遍脚本：它只装进 ~/Applications，会校验 SHA-256，不需要 sudo），
跑完把最后一行提示原样告诉我（要不要重启 Codex、要不要先登录 Codex 桌面，它都会说）；连不上 GitHub 就让我打开代理软件的「系统代理」后重跑，不要用 sudo 或绕过 macOS 的安全检查，其他报错也原样告诉我。
```

A local-first macOS menu-bar app for multiple Codex accounts. macOS 菜单栏的多账号 Codex 工具：看清每个账号的额度，并让 Codex 自动挑有额度的账号用。

**测试版 v0.4.17-beta.1** · macOS 14+ · Apple 芯片 · MIT · [下载](https://github.com/ruanjianjian/codex-account-manager/releases)

## 一行安装

先登录 Codex 桌面，再在终端运行：

```sh
curl -fsSL https://raw.githubusercontent.com/ruanjianjian/codex-account-manager/main/scripts/get.sh | bash
```

脚本下载最新安装包并核对 SHA-256，旧版移到废纸篓（账号和设置保留），装进 `~/Applications` 后打开。Tibot 会自己完成三步：登录凭据改存本机私有目录（与 Codex 默认方式一致，文件不加密）、连接 Codex 桌面正在登录的账号、开启自动路由。第一次装好后重启一次 Codex，让已经开着的会话也经过路由；以后更新（包括自动更新）都不用重启 Codex。

用命令行下载的文件没有浏览器的“来自互联网”标记，所以不会出现 macOS 的手动放行步骤；安装包仍未经 Apple 公证，可信度来自本仓库和 SHA-256 校验。装好后会自动更新：Tibot 每 6 小时检查一次新版，在没有 Codex 请求的空闲时刻自己下载、校验（SHA-256、签名、版本）、替换并重启，账号和设置保留；设置里可以关掉「自动更新」。手动更新就重跑同一条命令，账号和登录同样保留，不用重新授权。用过私人版（数据在 `~/Library/Application Support/CodexAccountManager`）的，第一次打开会自动导入它的账号和登录；私人版还开着时会等它退出再导入。导入后只用这个版本，别再打开私人版，免得两边互相顶掉登录。只想安装、不自动设置：`CODEX_ACCOUNTS_SKIP_SETUP=1`。需要代理才能上 GitHub 时，脚本会自动使用 macOS 的系统代理（终端已设置 `https_proxy` 时以终端为准），下载失败会自动重试。

独立社区工具，与 OpenAI、X 无隶属或背书关系。所有账号都由使用者自行登录；不附带账号、API Key、Cookie 或任何个人登录数据。

## 遇到问题

**Codex 报 `502 Bad Gateway: Unknown error`（地址是 127.0.0.1:18456）**：网关连不上 ChatGPT，常见于需要代理才能上 ChatGPT 的网络。v0.4.8 起网关和 Codex 一样走这台 Mac 的代理，重跑上面的一行安装命令更新即可；不跑的话，空闲时最晚约 6 小时也会自动更新。账号、登录和路由都保留，不用重启 Codex，也不用重新授权。

代理需要满足其中一种：

- 设成 macOS 的系统代理，即「系统设置 → 网络 → 代理」里的 HTTPS 或 SOCKS 代理。Clash 等代理软件打开「系统代理」就是这种。
- 代理软件用 TUN / 增强模式接管全部流量，这时一般不需要额外设置。

暂不支持「自动代理配置（PAC）」。只在终端里 `export https_proxy` 对 Tibot 不生效，因为 Tibot 不是从终端启动的。

**额度用完的账号上的旧会话报错、不换账号**：0.4.10 以前，带加密历史的旧会话只能留在原账号。0.4.10 起原账号不可用时会换到其他有额度的账号继续，重跑一行安装命令更新即可。

## 能做什么

- 无限数量的账号卡片：官方额度窗口、重置时间、banked reset 数量与到期信息。
- 近7天 token 柱状图，展开查看更长日期；缺失数据保留为未知，不补零。
- 菜单栏悬停呼出，移出/点击外部收起；可调整大小、置顶、选择两键快捷键。
- 可把账号卡片嵌入桌面：横排组件默认放在系统桌面小组件右侧、顶部对齐，按住空白处或卡片拖动，被其他窗口覆盖。开启路由时显示像素路由动效。
- 面板和桌面组件显示两个状态点：「路由」绿点表示最近一次请求经网关成功完成，「缓存」绿点表示它命中了 prompt cache（悬停看命中 token）。
- 各账号独立 Codex 登录目录，持久登录；支持 Chrome Profile 或账号专用浏览器窗口。
- 可选 Tibo 重置提醒：登录个人 X 后每分钟读取 Tibo 主页；他预告重置时立即发系统通知，写明约几小时后重置、哪些账号还有余量，提醒抓紧用掉；同时刷新所有账号官方额度。首次只建立基线，不重播历史帖，不使用 banked reset。

额度是服务端账号总额度，包含该账号在其他电脑上的使用，无需在其他电脑也装本工具。不能按设备拆分消耗，也不把百分比换算成 token。

## 自动账号路由

1. 第一次打开时，看板顶部的「自动路由」卡片列出两步：**改用本机文件存储**、**连接 Codex 桌面正在登录的账号**（直接读取这个登录，不用再去浏览器登录一次）。
2. 两步完成后路由自动开启：保存原 Codex 配置，保留官方 provider 和 Fast 设置，只把推理地址指向本机网关。在设置里关掉后，不会再自动开启。
3. 新会话立刻经过网关；已经打开的会话重启 Codex 后也会经过网关。之后请求由网关选择账号，无需为每个请求切换桌面登录。
4. 会话始终留在第一次承接它的账号上，以复用该账号的 prompt cache；该账号不可用时才换。新会话默认先用**最早重置**的可用账号（按每周额度的重置时间），快过期的额度先用掉，用完再换下一个；也可在设置「新会话优先」或点击账号名称指定某个账号，再点一次改回自动。改指定不会把进行中的会话挪走。仅输出开始前的可重试失败会尝试备用账号。
5. 关闭开关会恢复原 provider，保留期间对其他设置的修改；如网关配置项本身被其他程序改动，会拒绝覆盖并保留备份。关闭后同样重启 Codex。v0.3.0 创建的自定义 provider 会话仍需网关开启才能继续。

**使用期间保持 Tibot 运行。** 私有版本与公开版不能同时接管同一个默认 Codex 配置；先关闭另一版本的路由。

网关是独立实现的 Go 辅助进程（压缩协议依赖 klauspost/compress）。真实官方 CLI 的模型回复与终端工具调用已验证；官方 CLI 已验证直连创建会话后，经网关续聊能保留历史并执行工具。默认 Codex 桌面重启后的旧会话和 Fast 按钮显示仍待验收，先按实验功能使用。已输出内容/工具调用不会自动重放。会话先留在第一次回答它的账号上，保住提示缓存；绑定保存在本机，网关重启后继续使用。这个账号额度用完、冷却或登录过期时，会话连同加密历史和压缩内容一起换到其他有额度的账号继续，换过去的第一次没有缓存，会多用一些额度。客户端在发请求前自己拦截时仍会报错。原生云端/远程功能尚未完整验收。

网关连 ChatGPT 时和 Codex 一样走这台 Mac 的代理（先看 `https_proxy` 等环境变量，再看系统设置里的 HTTPS / SOCKS 代理，每 30 秒重读；自动代理 PAC 不支持），需要代理才能上 ChatGPT 的网络也能用。网关只监听本机，使用独立随机密钥；只导出短期 access token，沿用原采集进程管理 OAuth 刷新。网关凭据及配置备份位于数据目录 `gateway/`，禁止上传。详见 [网关说明](Gateway/README.md) 与 [验证记录](docs/VALIDATION.md)。

## 登录保存在本机文件，不用钥匙串

- 「直接切换桌面账号」已删除（它要退出 Codex、替换登录文件，并跟着 Codex 版本维护白名单）。点账号名称改为「设为新会话优先」；自动路由未开时会先询问是否开启。要换 Codex 桌面本身登录的账号，请在 Codex 里登出再登录。
- 各账号的登录保存在数据目录的 `accounts/<id>/auth.json`（目录 700、文件 600），和 Codex 自己的 `~/.codex/auth.json` 一样：只有当前 macOS 用户能读写，**文件本身不加密，同一用户下运行的程序可能读取**。好处是安装、更新、自动更新都不会弹钥匙串授权框。
- 以前用钥匙串保存登录的旧版本，第一次打开新版时会自动把登录搬到文件里：macOS 可能每个账号问一次是否允许，只此一次，之后不再访问钥匙串。读不出来的账号（比如点了拒绝）会提示重新连接，其他账号照常。
- 当前用于桌面的账号不能直接重新连接或移除；请先在 Codex 里登录其他账号。

## 从旧测试版升级

推荐直接重跑一行安装命令，或等自动更新。手动升级时退出旧版，把旧应用（0.4.9 以前叫 **Codex Accounts Beta.app**）移到废纸篓，再放入新版。**不要删除 `CodexAccountsPublic` 数据目录**，已连接账号和偏好会保留。旧名字的 App 第一次打开会自己改名为 Tibot.app。

## 手动安装下载版

1. 在 [Releases](https://github.com/ruanjianjian/codex-account-manager/releases) 下载 `Codex-Accounts-v0.4.17-beta.1-macos-arm64.zip` 和 `SHA256SUMS.txt`。在同一目录执行 `shasum -a 256 -c SHA256SUMS.txt` 核对文件。
2. 解压，将 App 拖入 `~/Applications`。若没有这个文件夹，可自己新建。
3. 安装 [Google Chrome](https://www.google.com/chrome/) 到 `/Applications`，并安装官方 [Codex CLI](https://github.com/openai/codex)。装了 Codex 桌面（ChatGPT App）就自带 CLI，本版用其内置 CLI 0.165 验证；旧版 CLI 可能不支持 token 活动或 banked reset 字段，缺失时显示未知。
4. 双击打开应用；若 macOS 拦截，请按下方「首次打开：手动放行」操作。启动后从菜单栏进入，点击右上角 `+`，自行完成 Codex 授权和必要的2FA。

### 首次打开：手动放行

当前测试版暂不进行 Apple 公证，下载包仅作 ad-hoc 签名，**未经 Apple Developer ID 签名或公证**。下载和使用本工具不需要购买 Apple Developer 会员。

确认下载来自本仓库的 Release 且上面的 SHA-256 校验通过后，如遇到「无法验证开发者」或「Apple 无法检查是否包含恶意软件」提示：

1. 先双击 App 尝试打开；出现拦截提示时关闭提示，保留应用。
2. 打开 Mac 的 **系统设置 → 隐私与安全性**，向下滚动到「安全性」。
3. 找到针对 **Tibot** 的拦截提示，点 **「仍要打开」**。
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

产物默认位于 `dist/Tibot.app`；缓存位于 `.build`。可设置 `PUBLIC_DIST_DIR` 指定产物目录。脚本拒绝覆盖现有构建和已安装的同名应用；更新时先退出公开版，将旧应用（Tibot.app，或 0.4.9 以前的 Codex Accounts Beta.app）移到废纸篓，再安装新版，应用数据仍保留。

本工具不打包 Codex CLI，按顺序发现常见 npm、Codex/ChatGPT 应用及 Homebrew 安装位置。若提示未找到 CLI，请确认 `codex --version` 可用且位于 `/opt/homebrew/bin/codex` 或 `/usr/local/bin/codex`，或使用支持的应用内置路径。

## 初次使用与隔离

- 初次启动为空账号列表。自动路由在完成两步设置后自动开启；重置提醒、通知、开机启动和全局快捷键默认关闭，可在设置中启用。
- 公开版标识为 `io.github.ruanjianjian.codex-accounts`，数据独立保存在 `~/Library/Application Support/CodexAccountsPublic/`。
- 不自动导入其他应用的数据。自动路由会修改默认 Codex 的 provider 配置（关闭或退出 Tibot 时恢复），但不修改登录文件。WebKit 的 X 登录态和应用偏好也使用公开版独立身份。
- 若已有个人构建，可同时保留；不要给两者配置相同快捷键。不同 Codex 客户端同时发起 OAuth 可能争用 localhost 回调端口，请按次完成授权。
- 账号菜单可重新连接或移除连接。登录失效时需要重新连接。

## Tibo 重置提醒

设置 → 重置提醒 → 登录 X → 用自己的邮箱/用户名登录。登录后自动打开 Tibo 主页并开始监控，窗口可以关闭，后台每分钟检查；打开该窗口时暂停后台导航，避免打断输入。失败会退避，休眠/退出时停止，唤醒补查。

Tibo 预告重置时发系统通知（点开即原帖），时间只取帖子原文（如 "in 5 hours"、"tomorrow"），读不出就写「重置时间未说明」；预告期间桌面组件和面板顶部显示倒计时。宣布已重置、发放 banked reset 也会通知；含糊的活动帖只刷新额度，不通知。

这是可见页面抓取，不是 X 推送接口。只覆盖主页已加载的本人帖子，可能漏掉回复、被折叠内容或断线期间的帖子；页面结构、限流、登录验证都可能导致失败。简短 reset 活动帖只作为查询额度的信号，不代表官方额度已经重置。不支持 Google/Apple 外部登录跳转。

未登录 X 时开启提醒会改用第三方公告源 `codexreset-news.com`，约5分钟检查一次，可能延迟。首次启动不会自动请求它。


## 隐私、安全与限制

详见 [PRIVACY.md](PRIVACY.md)、[SECURITY.md](SECURITY.md) 和 [测试版验证记录](docs/VALIDATION.md)。请勿在 Issue 上传账户目录、Cookie、Key、OAuth 回调链接或未经脱敏的截图。

账号/额度读取使用官方 Codex app-server 的实验协议，不保证所有套餐、CLI 版本或未来接口兼容。额度查询本身不发起模型推理，也不代用重置券。开启路由后，模型请求会自动选择账号。实际额度以官方返回为准。

## 卸载

先在公开版设置中关闭「自动账号路由」并重启 Codex，再关闭「登录 Mac 时启动」，按需从账号菜单移除账号连接，然后退出并将 **Tibot.app** 移到废纸篓。删除应用本身不会删除登录和缓存。如需清除，使用设置里的「打开本机数据目录」核对公开版目录后手动删除；X 网站数据由系统 WebKit 存储，应用重装后可能仍保留。不要删除其他客户端的目录或钥匙串条目。

## 第三方组件

网关的压缩协议使用 [klauspost/compress](https://github.com/klauspost/compress)，许可见 `Gateway/THIRD-PARTY-NOTICES.txt`。

## 贡献

欢迎通过 Issue 提交已脱敏的系统版本、CLI版本、复现步骤与错误类别。PR 请运行 `swift test` 与 `./scripts/build.sh`，不要提交真实账号信息。发布前运行 `gitleaks git . --redact` 和 `gitleaks dir . --redact`。

供发布者将来选择使用的签名、公证与票据校验流程见 [NOTARIZATION.md](docs/NOTARIZATION.md)；它不是安装步骤。当前测试包仍以 Release 标注的签名状态为准。

[MIT License](LICENSE)

### 实时路由图

开启自动路由后，组件顶部会显示 Codex → 本机网关 → 账号的实时流向。活动请求以光点和账号高亮展示，支持并发、完成和换路计数，点击标题可收起。无请求时停止动画；遵循 macOS 减少动态效果设置。统计只覆盖本次 Tibot 启动期间。
