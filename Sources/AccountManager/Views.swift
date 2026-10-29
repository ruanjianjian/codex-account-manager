import SwiftUI
import AccountCore

private let accent = Color(red: 0.10, green: 0.43, blue: 0.38)

struct QuotaLine: View {
    let window: QuotaWindow
    let prefix: String?
    let now: Date
    let fresh: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(window.remaining.map { "\(Int($0))%" } ?? "—")
                    .font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(!fresh ? Color.secondary : (window.remaining ?? 0 <= 15 ? Color.orange : accent))
                    .frame(width: 65, alignment: .leading)
                Text((prefix.map { $0 + " · " } ?? "") + window.label).font(.caption).lineLimit(1)
                Spacer(minLength: 5)
                Text(Presentation.countdown(window.resetDate, now: now)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let remaining = window.remaining {
                ProgressView(value: remaining, total: 100).tint(fresh ? accent : .gray).accessibilityLabel("\(window.label)剩余 \(Int(remaining))%")
            }
            if let date = window.resetDate {
                Text("重置于 \(date.formatted(.dateTime.month().day().hour().minute()))").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct AccountEditor: View {
    @ObservedObject var store: AppStore
    let slot: AccountSlot
    let onClose: () -> Void
    @State private var name: String
    @State private var profile: String
    init(store: AppStore, slot: AccountSlot, onClose: @escaping () -> Void) {
        self.store = store; self.slot = slot; self.onClose = onClose
        _name = State(initialValue: slot.nameOverride ?? ""); _profile = State(initialValue: slot.chromeProfile)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("名称与浏览器").font(.title2.weight(.semibold))
            Form {
                TextField("自定义名称（留空使用 Codex 名称）", text: $name)
                Picker("Chrome Profile", selection: $profile) { ForEach(store.profiles) { Text($0.name).tag($0.id) } }
            }
            Text("多个 Codex 账号可以共用一个 Chrome Profile。这里只决定授权页在哪个窗口打开；请在 OpenAI 页面选择对应账号。成功后，各账号独立保存登录，日常查询不用切换浏览器。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("取消") { onClose() }; Button("保存") { store.rename(slot.id, name: name, profile: profile); onClose() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!store.canConnect || store.loginSlotID == slot.id) }
        }.padding(26).frame(width: 460)
    }
}

struct AccountDetails: View {
    @ObservedObject var store: AppStore
    let accountID: String
    let onClose: () -> Void
    var body: some View {
        let slot = store.slot(accountID)
        VStack(alignment: .leading, spacing: 18) {
            Text("\(slot?.displayName ?? "账号") · 额度详情").font(.title2.weight(.semibold))
            if let snapshot = slot?.snapshot {
                Text(Presentation.maskedEmail(snapshot.identity.email)).font(.caption).foregroundStyle(.secondary)
                ForEach(Array(snapshot.rates.windows.enumerated()), id: \.offset) { _, quota in
                    QuotaLine(window: quota, prefix: nil, now: store.now, fresh: snapshot.isFresh(at: store.now))
                }
                if snapshot.rates.ordinaryUsageAllowed == false || snapshot.rates.buckets.contains(where: { $0.1.rateLimitReachedType != nil || $0.1.spendControlReached == true }) {
                    Text("服务返回了使用限制，请在账号用量页面查看。").font(.caption).foregroundStyle(.orange)
                }
            }
            Text("可用 banked reset：\(slot?.snapshot?.rates.rateLimitResetCredits?.availableCount.map(String.init) ?? "未知")").font(.headline)
            Text("数量以服务返回的总数为准，明细可能只返回部分条目。第一版仅展示，不会消耗 reset。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if (slot?.snapshot?.rates.rateLimitResetCredits?.credits ?? []).isEmpty {
                        Text("暂无 reset 明细").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(slot?.snapshot?.rates.rateLimitResetCredits?.credits ?? []) { credit in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(credit.title ?? "Rate-limit reset").font(.callout.weight(.medium))
                            Text("状态：\(credit.status ?? "未知") · " + (credit.expiresAt.map { "到期于 \(Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened))" } ?? "无到期时间"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: CGFloat(max(1, min(3, slot?.snapshot?.rates.rateLimitResetCredits?.credits?.count ?? 0))) * 60)
            if let snapshot = slot?.snapshot { Text("最后同步：\(snapshot.fetchedAt.formatted(date: .abbreviated, time: .standard))").font(.caption).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("完成") { onClose() }.keyboardShortcut(.defaultAction) }
        }.padding(26).frame(width: 500)
    }
}

struct GeneralSettings: View {
    @ObservedObject var store: AppStore
    let onClose: () -> Void
    @State private var showDeepSeek = false
    let openPersonalX: () -> Void
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            Text("管家设置").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 7) {
                Toggle("自动账号路由", isOn: Binding(get: { store.gatewayEnabled }, set: { store.setGatewayEnabled($0) }))
                Text(store.gatewayCaption).font(.caption).foregroundStyle(.secondary)
                if store.gatewayEnabled {
                    Picker("新会话优先", selection: Binding(get: { store.gatewayPreferred }, set: store.selectGatewayAccount)) {
                        Text("自动选择").tag("")
                        ForEach(store.saved.accounts) { Text($0.displayName).tag($0.id) }
                    }
                    if !store.gatewayReady { Button("重试启动网关") { store.setGatewayEnabled(true, confirm: false) } }
                }
                Text("保留官方连接方式与 Fast 设置；重启 Codex 后，新旧会话都可通过网关。新请求自动选择账号；加密历史保持原账号，原账号不可用时提示，不重放工具。使用期间保持管家运行。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("登录存储").font(.headline)
                Text(store.usesFileCredentials ? "本机文件 · 仅当前系统用户可读写" : "系统钥匙串 · 跨应用写回可能再次要求授权")
                    .font(.caption).foregroundStyle(.secondary)
                if !store.usesFileCredentials {
                    Button(store.migratingCredentials ? "正在迁移…" : "改用本地文件存储…") { store.enableFileCredentials() }
                        .disabled(store.preview || !store.saved.accounts.contains(where: { $0.expectedAccountID != nil }) || store.migratingCredentials || store.loginSlotID != nil || !store.launchingDesktop.isEmpty)
                    Text("先连接账号，再选择迁移。需确认存储方式变化；不会自动迁移或删除原钥匙串记录。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("个人 X 监控").font(.headline)
                Text(store.personalXCaption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("登录 / 查看个人 X", action: openPersonalX).disabled(store.preview)
                    if store.personalX.enabled { Button("停用个人 X") { store.disablePersonalX() }.disabled(store.personalXTesting) }
                }
                Text("独立登录自己的 X，读取 Tibo 主页。无需 DeepSeek Key。首次读取建立基线，后续每分钟检测；新重置公告才刷新账号。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let post = store.personalX.lastPosts.first, let link = post.originalURL {
                    Link("最近读到：" + (post.date?.formatted(date: .abbreviated, time: .shortened) ?? post.id), destination: link).font(.caption)
                    Text(verbatim: String(post.text.prefix(200))).font(.caption).lineLimit(4)
                }
                Button("DeepSeek 实验性测试…") { showDeepSeek = true }.font(.caption)
            }
            Text("悬停菜单栏可展开，移出或点击外部自动收起；置顶后保持显示。账号名称保存在本机，刷新和重启不会为读取名称访问钥匙串。新增账号可填写名称，留空时显示脱敏邮箱。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("显示桌面组件", isOn: Binding(get: { store.desktopVisible }, set: store.setDesktopVisible))
            Toggle("桌面组件置顶", isOn: Binding(get: { store.desktopPinned }, set: store.setDesktopPinned))
            Picker("呼出 / 隐藏", selection: Binding(get: { store.shortcutChoice }, set: store.setShortcut)) {
                Text("不启用快捷键").tag("none")
                Text("⌥ 空格").tag("space")
                Text("⌃ ;（Control＋分号）").tag("ctrl-semicolon")
                Text("⌥ X").tag("x")
            }
            if let issue = store.shortcutIssue { Text(issue).font(.caption).foregroundStyle(.red) }
            Toggle("登录 Mac 时启动", isOn: Binding(get: { store.loginAtLaunch }, set: store.setLoginAtLaunch)).disabled(store.preview)
            Toggle("重要变化发送系统通知", isOn: Binding(get: { store.saved.notificationsEnabled }, set: store.setNotifications)).disabled(store.preview)
            Text("提醒额度恢复、临近重置仍有余量，以及 banked reset 即将到期。相同事件不重复提醒。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("读取账号在所有设备上的服务端总额度，每分钟自动同步，呼出时补查。无法按电脑拆分消耗；服务端更新可能有延迟。退出或休眠时暂停，唤醒补查，失败延后重试。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Toggle("监控 Tibo 重置公告", isOn: Binding(get: { store.resetMonitor.enabled }, set: store.setResetMonitoring)).disabled(store.preview)
                HStack {
                    Text(store.resetMonitorCaption).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("立即检查") { store.checkResetAnnouncements(force: true) }
                        .disabled(store.preview || !store.resetMonitor.enabled || store.checkingResetAnnouncements)
                }
                Text(store.personalX.enabled ? "来源：本机个人 X 登录态。每分钟检查；打开 X 登录窗口时暂缓后台检查。失败退避、唤醒补查；实际额度以账号返回为准。" : "每5分钟检查；发现新公告自动刷新所有账号。公告源有延迟时会标注，实际额度以账号返回为准。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let result = store.resetRefreshCaption {
                    Text(result).font(.caption)
                    if let link = store.resetMonitor.lastAnnouncement?.originalURL { Link("查看公告原帖", destination: link).font(.caption) }
                }
                if !store.personalX.enabled { HStack {
                    Link("公告源：Codex Reset News（第三方）", destination: URL(string: "https://www.codexreset-news.com/developers?lang=en")!)
                    Link("上游：codex-reset.com", destination: URL(string: "https://codex-reset.com/")!)
                }.font(.system(size: 10)) }
                if let updated = store.resetMonitor.sourceUpdatedAt {
                    Text("源更新：" + updated.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("最近动态") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(store.saved.events.prefix(8)) { event in
                            Text("\(event.time.formatted(date: .omitted, time: .shortened))  \(event.text)")
                                .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.frame(height: 120)
            }
            Button("打开本机数据目录") { NSWorkspace.shared.open(store.root) }
            HStack { Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") · 仅本机存储").font(.caption).foregroundStyle(.secondary); Spacer(); Button("完成") { onClose() }.keyboardShortcut(.defaultAction) }
        }.padding(26).frame(maxWidth: .infinity)
        }.frame(width: 440, height: min(700, (NSScreen.main?.visibleFrame.height ?? 800) - 100))
        .sheet(isPresented: $showDeepSeek) {
            DeepSeekTestView(store: store, onClose: { showDeepSeek = false })
        }
    }
}

struct AccountAdder: View {
    @ObservedObject var store: AppStore
    let onClose: () -> Void
    @State private var profile = "dedicated"
    @State private var alias = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("添加 Codex 账号").font(.title2.weight(.semibold))
            Picker("Chrome Profile", selection: $profile) {
                ForEach(store.profiles) { Text($0.name).tag($0.id) }
            }
            TextField("Codex 名称（可留空）", text: $alias)
            Text("登录后自动读取身份与额度；填写名称后显示在看板。多个账号可共用Chrome Profile，数量不设上限。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消") { onClose() }
                Button("添加并连接") { store.addAccount(profile: profile, alias: alias); onClose() }
                    .buttonStyle(.borderedProminent).disabled(!store.canConnect || store.loginSlotID != nil)
            }
        }.padding(26).frame(width: 460)
    }
}


enum WidgetAction {
    case activity, settings, personalX, add, edit(AccountSlot), details(String), remove(AccountSlot)
    var title: String {
        switch self {
        case .activity: return "Token 活动"
        case .settings: return "管家设置"
        case .personalX: return "个人 X · Tibo 监控"
        case .add: return "添加账号"
        case .edit: return "名称与浏览器"
        case .details: return "额度详情"
        case .remove: return "移除账号"
        }
    }
}

struct WidgetActionView: View {
    @ObservedObject var store: AppStore
    let action: WidgetAction
    let onClose: () -> Void
    let present: (WidgetAction) -> Void
    var body: some View {
        Group {
            switch action {
            case .activity: TokenActivityDetails(store: store, onClose: onClose)
            case .settings: GeneralSettings(store: store, onClose: onClose, openPersonalX: { present(.personalX) })
            case .personalX: PersonalXLoginView(store: store, onClose: onClose)
            case .add: AccountAdder(store: store, onClose: onClose)
            case .edit(let slot): AccountEditor(store: store, slot: slot, onClose: onClose)
            case .details(let id): AccountDetails(store: store, accountID: id, onClose: onClose)
            case .remove(let slot):
                VStack(alignment: .leading, spacing: 20) {
                    Text("移除“\(slot.displayName)”？").font(.title2.weight(.semibold))
                    Text("从组件移除这个账号，并清除管家保存的登录和额度快照。Chrome 和当前 Codex 的登录不受影响。")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("取消", action: onClose).keyboardShortcut(.cancelAction)
                        Button("移除账号", role: .destructive) {
                            Task { await store.disconnect(slot.id) }; onClose()
                        }.disabled(store.loginSlotID != nil || store.status[slot.id] == .checking || !store.canConnect)
                    }
                }.padding(26).frame(width: 420)
            }
        }.tint(accent)
    }
}
