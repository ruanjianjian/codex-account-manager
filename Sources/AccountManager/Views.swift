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
                ProgressView(value: remaining, total: 100).tint(fresh ? accent : .gray).accessibilityLabel(L("\(window.label)剩余 \(Int(remaining))%", "\(window.label) \(Int(remaining))% left"))
            }
            if let date = window.resetDate {
                Text(L("重置于 \(date.formatted(.dateTime.month().day().hour().minute()))", "Resets \(date.formatted(.dateTime.month().day().hour().minute()))")).font(.caption2).foregroundStyle(.secondary)
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
            Text(L("名称与浏览器", "Name and browser")).font(.title2.weight(.semibold))
            Form {
                TextField(L("自定义名称（留空使用 Codex 名称）", "Custom name (empty uses the Codex name)"), text: $name)
                Picker("Chrome Profile", selection: $profile) { ForEach(store.profiles) { Text($0.name).tag($0.id) } }
            }
            Text(L("多个 Codex 账号可以共用一个 Chrome Profile。这里只决定授权页在哪个窗口打开；请在 OpenAI 页面选择对应账号。成功后，各账号独立保存登录，日常查询不用切换浏览器。", "Several Codex accounts can share one Chrome profile. This only picks the window the sign-in page opens in; choose the matching account on the OpenAI page. Afterwards each account keeps its own login, so everyday checks never switch browsers."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button(L("取消", "Cancel")) { onClose() }; Button(L("保存", "Save")) { store.rename(slot.id, name: name, profile: profile); onClose() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!store.canConnect || store.loginSlotID == slot.id) }
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
            Text(L("\(slot?.displayName ?? "账号") · 额度详情", "\(slot?.displayName ?? "Account") · Quota details")).font(.title2.weight(.semibold))
            if let snapshot = slot?.snapshot {
                Text(Presentation.maskedEmail(snapshot.identity.email)).font(.caption).foregroundStyle(.secondary)
                ForEach(Array(snapshot.rates.windows.enumerated()), id: \.offset) { _, quota in
                    QuotaLine(window: quota, prefix: nil, now: store.now, fresh: snapshot.isFresh(at: store.now))
                }
                if snapshot.rates.ordinaryUsageAllowed == false || snapshot.rates.buckets.contains(where: { $0.1.rateLimitReachedType != nil || $0.1.spendControlReached == true }) {
                    Text(L("服务返回了使用限制，请在账号用量页面查看。", "The service reported a usage restriction; see the account's usage page.")).font(.caption).foregroundStyle(.orange)
                }
            }
            Text(L("可用 banked reset：\(slot?.snapshot?.rates.rateLimitResetCredits?.availableCount.map(String.init) ?? "未知")", "Banked resets available: \(slot?.snapshot?.rates.rateLimitResetCredits?.availableCount.map(String.init) ?? "unknown")")).font(.headline)
            Text(L("数量以服务返回的总数为准，明细可能只返回部分条目。第一版仅展示，不会消耗 reset。", "The count is the service's total; the details may list only some. Tibot only shows them and never uses a reset."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if (slot?.snapshot?.rates.rateLimitResetCredits?.credits ?? []).isEmpty {
                        Text(L("暂无 reset 明细", "No reset details")).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(slot?.snapshot?.rates.rateLimitResetCredits?.credits ?? []) { credit in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(credit.title ?? "Rate-limit reset").font(.callout.weight(.medium))
                            Text(L("状态：\(credit.status ?? "未知") · ", "Status: \(credit.status ?? "unknown") · ") + (credit.expiresAt.map { L("到期于 \(Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened))", "expires \(Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened))") } ?? L("无到期时间", "no expiry")))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: CGFloat(max(1, min(3, slot?.snapshot?.rates.rateLimitResetCredits?.credits?.count ?? 0))) * 60)
            if let snapshot = slot?.snapshot { Text(L("最后同步：\(snapshot.fetchedAt.formatted(date: .abbreviated, time: .standard))", "Last synced: \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .standard))")).font(.caption).foregroundStyle(.secondary) }
            HStack { Spacer(); Button(L("完成", "Done")) { onClose() }.keyboardShortcut(.defaultAction) }
        }.padding(26).frame(width: 500)
    }
}

struct GeneralSettings: View {
    @ObservedObject var store: AppStore
    let onClose: () -> Void
    let openPersonalX: () -> Void
    private let paper = Color(red: 0.065, green: 0.085, blue: 0.105)
    private let mint = Color(red: 0.55, green: 0.96, blue: 0.78)
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("CODEX / SETTINGS").font(.system(size: 12, weight: .heavy)).tracking(0.6)
                Spacer()
            }.padding(.horizontal, 14).padding(.top, 34).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    routing
                    caption(L("显示", "Display"))
                    card {
                        row(L("语言", "Language")) {
                            Picker(L("语言", "Language"), selection: Binding(get: { store.language }, set: store.setLanguage)) {
                                Text(L("跟随系统", "System")).tag(UILanguage.system)
                                Text("中文").tag(UILanguage.zh)
                                Text("English").tag(UILanguage.en)
                            }.pickerStyle(.menu).labelsHidden().fixedSize()
                        }
                        Divider()
                        row(L("桌面组件", "Desktop widget")) {
                            Picker(L("桌面组件", "Desktop widget"), selection: Binding(get: { store.desktopMode }, set: store.setDesktopMode)) {
                                Text(L("关闭", "Off")).tag(AppStore.DesktopMode.off)
                                Text(L("嵌入桌面", "Desktop")).tag(AppStore.DesktopMode.embedded)
                                Text(L("置顶浮动", "On top")).tag(AppStore.DesktopMode.floating)
                            }.pickerStyle(.segmented).labelsHidden().fixedSize()
                        }
                        Divider()
                        row(L("呼出 / 隐藏", "Show / hide")) {
                            Picker(L("呼出 / 隐藏", "Show / hide"), selection: Binding(get: { store.shortcutChoice }, set: store.setShortcut)) {
                                Text(L("不启用", "None")).tag("none")
                                Text(L("⌥ 空格", "⌥ Space")).tag("space")
                                Text("⌃ ;").tag("ctrl-semicolon")
                                Text("⌥ X").tag("x")
                            }.pickerStyle(.menu).labelsHidden().fixedSize()
                        }
                        if let issue = store.shortcutIssue { note(issue).foregroundStyle(.red).padding(.bottom, 8) }
                    }
                    caption(L("提醒", "Alerts"))
                    card {
                        row(L("额度变化通知", "Quota change notifications")) { switchToggle(Binding(get: { store.saved.notificationsEnabled }, set: store.setNotifications)) }
                        Divider()
                        row(L("登录 Mac 时启动", "Open at login")) { switchToggle(Binding(get: { store.loginAtLaunch }, set: store.setLoginAtLaunch)) }
                        Divider()
                        row(L("自动更新", "Auto update")) { switchToggle(Binding(get: { store.autoUpdate }, set: store.setAutoUpdate)) }
                        if store.autoUpdate && !store.updateCaption.isEmpty { note(store.updateCaption).padding(.bottom, 8) }
                    }
                    caption(L("重置提醒", "Reset alerts"))
                    card {
                        row(L("Tibo 重置提醒", "Tibo reset alerts")) { switchToggle(Binding(get: { store.resetMonitor.enabled }, set: store.setResetMonitoring)) }
                        Divider()
                        row(L("用 Codex 判断公告", "Judge posts with Codex")) { switchToggle(Binding(get: { store.resetUsesModel }, set: store.setResetUsesModel)) }
                        note(store.resetUsesModel ? L("由你本机的 Codex 读每条新帖，能认出额度调整、读出具体时间；每条约用 2.6 万 tokens。", "Your own Codex reads each new post, so it catches limit changes and exact times; about 26K tokens per post.") : L("现在按关键词规则判断。打开后由你本机的 Codex 读帖，更准。", "Posts are judged by keyword rules now. Turn this on to have your own Codex read them, more accurately.")).padding(.bottom, 8)
                        Divider()
                        HStack(spacing: 6) {
                            Circle().fill(store.personalX.enabled && store.resetMonitor.enabled ? Color(red: 0.16, green: 0.66, blue: 0.3) : Color.secondary.opacity(0.35))
                                .frame(width: 6, height: 6)
                            note(store.resetSourceCaption).lineLimit(2)
                            Spacer(minLength: 6)
                            Button(store.personalX.enabled ? L("查看 X", "Open X") : L("登录 X", "Sign in to X"), action: openPersonalX).controlSize(.small).disabled(store.preview)
                            Button { store.checkResetAnnouncements(force: true) } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.plain).help(L("立即检查", "Check now")).accessibilityLabel(L("立即检查重置公告", "Check for reset announcements now"))
                                .disabled(store.preview || !store.resetMonitor.enabled || store.checkingResetAnnouncements)
                        }.padding(.vertical, 8)
                        if let post = store.resetMonitor.lastAnnouncement, let link = post.originalURL {
                            HStack(spacing: 6) {
                                note(latestAnnouncement(post)).lineLimit(1)
                                Spacer(minLength: 6)
                                Link(L("原帖", "Post"), destination: link).font(.system(size: 10))
                            }.padding(.bottom, 8)
                        }
                    }
                    caption(L("最近动态", "Recent activity"))
                    card {
                        DisclosureGroup(L("最近 8 条", "Last 8")) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(store.saved.events.prefix(8)) { event in
                                    note("\(event.time.formatted(date: .omitted, time: .shortened))  \(event.text)").frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.padding(.top, 6)
                        }.font(.system(size: 12, weight: .medium)).padding(.vertical, 9)
                    }
                }.padding(.horizontal, 14).padding(.bottom, 12)
            }.scrollIndicators(.hidden)
            HStack(spacing: 10) {
                Text(L("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") · 仅本机存储", "Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") · stored on this Mac only"))
                Spacer()
                Button(L("打开数据目录", "Open data folder")) { NSWorkspace.shared.open(store.root) }.buttonStyle(.plain)
                Button(L("完成", "Done")) { onClose() }.keyboardShortcut(.defaultAction).controlSize(.small)
            }.font(.system(size: 10, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 400, height: store.settingsHeight)
        .foregroundStyle(Color(white: 0.12))
        .background(Color(white: 0.97))
        .preferredColorScheme(.light)
    }
    private func latestAnnouncement(_ post: ResetAnnouncement) -> String {
        let when = post.isUpcoming(at: store.now) ? post.timing?.describe(now: store.now) : post.date?.formatted(date: .abbreviated, time: .shortened)
        let refreshed = post.kind == "possible_reset" ? "" : L(" · 已刷新 \(store.resetMonitor.refreshedAccountIDs.count)/\(store.resetMonitor.targetCount)", " · refreshed \(store.resetMonitor.refreshedAccountIDs.count)/\(store.resetMonitor.targetCount)")
        return L("最近：", "Latest: ") + post.label + (when.map { " · " + $0 } ?? "") + refreshed
    }
    private var routing: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(store.gatewayEnabled ? (store.gatewayReady ? mint : .orange) : .white.opacity(0.3)).frame(width: 5, height: 5)
                Text(L("自动账号路由", "Automatic account routing")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle(L("自动账号路由", "Automatic account routing"), isOn: Binding(get: { store.gatewayEnabled }, set: { store.setGatewayEnabled($0) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden().tint(Color(red: 0.1, green: 0.55, blue: 0.45))
            }.padding(.vertical, 9)
            if store.gatewayEnabled || store.routingSetup == .ready {
                Text(store.gatewayCaption).font(.system(size: 10)).foregroundStyle(.white.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, store.gatewayEnabled ? 4 : 10)
            } else {
                RoutingSetupSteps(store: store).padding(.bottom, 10)
            }
            if store.gatewayEnabled {
                Divider().overlay(Color.white.opacity(0.12))
                HStack {
                    Text(L("新会话优先", "Preferred for new chats")).font(.system(size: 12))
                    Spacer()
                    Picker(L("新会话优先", "Preferred for new chats"), selection: Binding(get: { store.gatewayPreferred }, set: store.selectGatewayAccount)) {
                        Text(L("自动：先用最早重置的", "Automatic: soonest reset first")).tag("")
                        ForEach(store.saved.accounts) { Text($0.displayName).tag($0.id) }
                    }.pickerStyle(.menu).labelsHidden().fixedSize()
                }.padding(.vertical, 6)
                if !store.gatewayReady {
                    Button(L("重试启动网关", "Retry starting the gateway")) { store.setGatewayEnabled(true) }.controlSize(.small).padding(.bottom, 8)
                }
            }
        }
        .padding(.horizontal, 12).foregroundStyle(.white)
        .background(paper, in: RoundedRectangle(cornerRadius: 12))
        .environment(\.colorScheme, .dark)
    }
    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(.secondary)
            .padding(.top, 14).padding(.bottom, 6).padding(.leading, 2)
    }
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
    }
    private func row<Trailing: View>(_ title: String, @ViewBuilder _ trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize()
            Spacer(minLength: 8)
            trailing()
        }.padding(.vertical, 8)
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func switchToggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden().disabled(store.preview)
            .tint(Color(red: 0, green: 0.46, blue: 0.53))
    }
}

struct AccountAdder: View {
    @ObservedObject var store: AppStore
    let onClose: () -> Void
    @State private var profile = "dedicated"
    @State private var alias = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L("添加 Codex 账号", "Add a Codex account")).font(.title2.weight(.semibold))
            Picker("Chrome Profile", selection: $profile) {
                ForEach(store.profiles) { Text($0.name).tag($0.id) }
            }
            TextField(L("自定义名称（可留空，默认显示 Codex 用户名）", "Custom name (optional; shows the Codex username by default)"), text: $alias)
            Text(L("登录后自动读取身份与额度；填写名称后显示在看板。多个账号可共用Chrome Profile，数量不设上限。", "After sign-in Tibot reads the identity and quota; a custom name shows on the board. Accounts can share a Chrome profile, with no limit on how many."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L("取消", "Cancel")) { onClose() }
                Button(L("添加并连接", "Add and connect")) { store.addAccount(profile: profile, alias: alias); onClose() }
                    .buttonStyle(.borderedProminent).disabled(!store.canConnect || store.loginSlotID != nil)
            }
        }.padding(26).frame(width: 460)
    }
}


enum WidgetAction {
    case activity, settings, personalX, add, edit(AccountSlot), details(String), remove(AccountSlot)
    var title: String {
        switch self {
        case .activity: return L("Token 活动", "Token activity")
        case .settings: return L("Tibot 设置", "Tibot Settings")
        case .personalX: return L("登录 X · Tibo 重置提醒", "Sign in to X · Tibo reset alerts")
        case .add: return L("添加账号", "Add account")
        case .edit: return L("名称与浏览器", "Name and browser")
        case .details: return L("额度详情", "Quota details")
        case .remove: return L("移除账号", "Remove account")
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
                    Text(L("移除“\(slot.displayName)”？", "Remove “\(slot.displayName)”?")).font(.title2.weight(.semibold))
                    Text(L("从组件移除这个账号，并清除 Tibot 保存的登录和额度快照。Chrome 和当前 Codex 的登录不受影响。", "Removes this account from the widget and deletes the login and quota snapshot Tibot saved. Chrome and the current Codex login are not affected."))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button(L("取消", "Cancel"), action: onClose).keyboardShortcut(.cancelAction)
                        Button(L("移除账号", "Remove account"), role: .destructive) {
                            Task { await store.disconnect(slot.id) }; onClose()
                        }.disabled(store.loginSlotID != nil || store.status[slot.id] == .checking || !store.canConnect)
                    }
                }.padding(26).frame(width: 420)
            }
        }.tint(accent)
    }
}
