# Public Beta scope

| ID | 类型 | 验收标准 | 落点 | 证据 |
| --- | --- | --- | --- | --- |
| PUB-01 | 核 | 首次启动显示空账号；应用、数据目录、偏好、X会话与其他构建隔离，不自动导入登录。 | macOS 原生 App | docs/VALIDATION.md |
| PUB-02 | 核 | 顶部加号可打开添加账号表单；默认无全局快捷键，公告监控默认关闭。 | macOS 原生 App | docs/VALIDATION.md |
| PUB-03 | 核 | 退出测试版不结束其他构建；发布包只有程序和通用资源。 | macOS 原生 App / 构建产物 | docs/VALIDATION.md |

| PUB-04 | 核 | 已连接账号名称提供确认后重启切号；默认home身份检查、进程阻塞与失败恢复保护有效，不自动切换。 | macOS 原生 App | docs/VALIDATION.md |
| PUB-05 | 核 | 文件存储显式同意，原钥匙串保留；700/600、身份校验和写完后启用；未确认不迁移。 | macOS 原生 App | docs/VALIDATION.md |
| PUB-06 | 核 | 钥匙串访问错误/超时暂停自动重试，单账号手动刷新恢复。 | macOS 原生 App | docs/VALIDATION.md |

发行范围：源码、MIT、构建/安装说明、Apple Silicon ad-hoc签名下载包。无需附带账号或开发者服务。X抓取、实验额度字段及Intel兼容性按README中的限制展示。
