# 隐私说明

本工具没有开发者服务器、遥测或分析上报。所有账号由使用者自行登录。

## 本机存储

- `~/Library/Application Support/CodexAccountsPublic/`：账号标识、完整邮箱、名称、Chrome Profile 绑定、额度/token缓存、提醒去重、公开X帖子与监控设置。目录0700，主要JSON文件0600。UI遮盖邮箱不代表磁盘JSON已匿名化。
- 每账号 `accounts/<id>/`：官方 Codex app-server 的独立 CODEX_HOME，凭据由官方 CLI 的 macOS Keychain 后端保存和刷新。
- 选择专用 Chrome 窗口时，`browsers/<id>/` 保存该浏览器会话。选择已有 Profile 时只启动对应窗口，不复制 Cookie。
- X 登录使用公开版应用身份下的 WebKit 持久网站存储，不导出 Cookie，不读取 Safari/Chrome 的 X Cookie。
- DeepSeek API Key 只存在进程内存；测试结果只保存公开正文及过滤后的状态，不保存 Key。退出后清除内存引用，不承诺对系统交换文件作安全擦除。

不要共享整个应用数据目录、钥匙串、浏览器存储、OAuth URL或日志。缓存中的完整邮箱/账号ID仍属于个人信息。

## 网络目的地与触发

- 添加/同步Codex账号：官方 Codex CLI 访问 OpenAI/ChatGPT 登录及服务端接口；账号额度每分钟、token活动约每5分钟读取。
- 自行开启个人X监控：访问 `x.com/thsottiaux` 及 X 页面依赖的资源。X会接收正常浏览器请求和该个人登录会话。
- 自行开启第三方公告监控：访问 `www.codexreset-news.com/api/v1/tibo`，不向公告源发送 Codex 登录凭据。
- 自行提交DeepSeek手动测试：Key和指定公开URL发送至 `api.deepseek.com`，不发送Codex账号信息。

首次空账号启动不发起上述采集请求。应用开启时读取本机 Chrome Profile 的目录名与显示名，供选择登录窗口；不会上传这些配置。

## 删除与控制

设置可关闭监控、通知、开机启动；账号菜单可注销/移除管家内的账号连接，不退出其他客户端或Chrome。卸载说明见README。系统和上游服务仍可能要求2FA或重新登录。
