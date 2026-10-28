# 隐私说明

本工具没有开发者服务器、遥测或分析上报。所有账号由使用者自行登录。

## 本机存储

- `~/Library/Application Support/CodexAccountsPublic/`：账号标识、完整邮箱、名称、Chrome Profile 绑定、额度/token缓存、提醒去重、公开X帖子与监控设置。目录0700，主要JSON文件0600。UI遮盖邮箱不代表磁盘JSON已匿名化。
- 每账号 `accounts/<id>/`：官方 Codex app-server 的独立 CODEX_HOME，默认由官方 CLI 的 macOS Keychain 后端保存和刷新；确认文件模式后保存在本目录的 `auth.json`，文件600、目录700，内容不加密，同一系统用户的程序可能读取。原钥匙串不删除。
- 选择专用 Chrome 窗口时，`browsers/<id>/` 保存该浏览器会话。选择已有 Profile 时只启动对应窗口，不复制 Cookie。
- X 登录使用公开版应用身份下的 WebKit 持久网站存储，不导出 Cookie，不读取 Safari/Chrome 的 X Cookie。
- DeepSeek API Key 只存在进程内存；测试结果只保存公开正文及过滤后的状态，不保存 Key。退出后清除内存引用，不承诺对系统交换文件作安全擦除。

不要共享整个应用数据目录、钥匙串、浏览器存储、OAuth URL或日志。缓存中的完整邮箱/账号ID仍属于个人信息。

主动切换桌面账号时，会读取、备份并原子替换默认 `~/.codex/auth.json`，退出再打开 Codex。项目、会话目录不搬迁。`desktop-switch/` 保存选择状态和恢复标记；文件模式下还保存含登录凭据的回退备份，权限600。迁移可能保留 `auth.json.before-file-mode` 备份，也含敏感凭据。钥匙串模式的回退备份使用公开版独立服务名，不与私人构建共用。

## 网络目的地与触发

- 添加/同步Codex账号：官方 Codex CLI 访问 OpenAI/ChatGPT 登录及服务端接口；账号额度每分钟、token活动约每5分钟读取。
- 自行开启个人X监控：访问 `x.com/thsottiaux` 及 X 页面依赖的资源。X会接收正常浏览器请求和该个人登录会话。
- 自行开启第三方公告监控：访问 `www.codexreset-news.com/api/v1/tibo`，不向公告源发送 Codex 登录凭据。
- 自行提交DeepSeek手动测试：Key和指定公开URL发送至 `api.deepseek.com`，不发送Codex账号信息。

首次空账号启动不发起上述采集请求。应用开启时读取本机 Chrome Profile 的目录名与显示名，供选择登录窗口；不会上传这些配置。

## 删除与控制

设置可关闭监控、通知、开机启动；账号菜单可注销/移除管家内的账号连接，不退出Chrome；当前用于桌面的账号禁止直接移除，需先切换至其他账号。卸载说明见README。系统和上游服务仍可能要求2FA或重新登录。

## 实验性本机网关

主动启用后，本机 Codex 推理请求经回环地址的辅助进程转发到 ChatGPT Codex 服务，使用你连接的账号。网关只读取应用导出的短期 access token，不刷新 OAuth、不读取钥匙串。pool.json、本机随机访问密钥、原配置备份保存在私有 gateway 目录，目录700、文件600，文件本身不加密。日志只记录时间、会话ID、账号槽位、状态及响应中的 token 计数，不记录提示词、工具正文或令牌。停用/退出会移除账号池快照；备份可能包含私有配置，禁止上传。

网关在本机 session-accounts.json 保存会话与账号槽位的绑定；requests.jsonl 保存有大小上限的诊断记录。两者不包含聊天内容或访问令牌，仍属于私人使用记录，请勿上传。原生连接使用已连接账号的有效token作本机鉴权，不接受未知或过期token。
