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
                    caption("显示")
                    card {
                        row("桌面组件") {
                            Picker("桌面组件", selection: Binding(get: { store.desktopMode }, set: store.setDesktopMode)) {
                                Text("关闭").tag(AppStore.DesktopMode.off)
                                Text("嵌入桌面").tag(AppStore.DesktopMode.embedded)
                                Text("置顶浮动").tag(AppStore.DesktopMode.floating)
                            }.pickerStyle(.segmented).labelsHidden().fixedSize()
                        }
                        Divider()
                        row("呼出 / 隐藏") {
                            Picker("呼出 / 隐藏", selection: Binding(get: { store.shortcutChoice }, set: store.setShortcut)) {
                                Text("不启用").tag("none")
                                Text("⌥ 空格").tag("space")
                                Text("⌃ ;").tag("ctrl-semicolon")
                                Text("⌥ X").tag("x")
                            }.pickerStyle(.menu).labelsHidden().fixedSize()
                        }
                        if let issue = store.shortcutIssue { note(issue).foregroundStyle(.red).padding(.bottom, 8) }
                    }
                    caption("提醒")
                    card {
                        row("额度变化通知") { switchToggle(Binding(get: { store.saved.notificationsEnabled }, set: store.setNotifications)) }
                        Divider()
                        row("登录 Mac 时启动") { switchToggle(Binding(get: { store.loginAtLaunch }, set: store.setLoginAtLaunch)) }
                    }
                    caption("重置提醒")
                    card {
                        row("Tibo 重置提醒") { switchToggle(Binding(get: { store.resetMonitor.enabled }, set: store.setResetMonitoring)) }
                        Divider()
                        HStack(spacing: 6) {
                            Circle().fill(store.personalX.enabled && store.resetMonitor.enabled ? Color(red: 0.16, green: 0.66, blue: 0.3) : Color.secondary.opacity(0.35))
                                .frame(width: 6, height: 6)
                            note(store.resetSourceCaption).lineLimit(2)
                            Spacer(minLength: 6)
                            Button(store.personalX.enabled ? "查看 X" : "登录 X", action: openPersonalX).controlSize(.small).disabled(store.preview)
                            Button { store.checkResetAnnouncements(force: true) } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.plain).help("立即检查").accessibilityLabel("立即检查重置公告")
                                .disabled(store.preview || !store.resetMonitor.enabled || store.checkingResetAnnouncements)
                        }.padding(.vertical, 8)
                        if let post = store.resetMonitor.lastAnnouncement, let link = post.originalURL {
                            HStack(spacing: 6) {
                                note(latestAnnouncement(post)).lineLimit(1)
                                Spacer(minLength: 6)
                                Link("原帖", destination: link).font(.system(size: 10))
                            }.padding(.bottom, 8)
                        }
                    }
                    caption("登录存储")
                    card {
                        row(store.usesFileCredentials ? "本机文件" : "系统钥匙串") {
                            if !store.usesFileCredentials {
                                Button(store.migratingCredentials ? "正在迁移…" : "改用本地文件存储…") { store.enableFileCredentials() }.controlSize(.small)
                                    .disabled(store.preview || store.migratingCredentials || store.loginSlotID != nil || !store.launchingDesktop.isEmpty)
                            } else { note("仅当前系统用户可读写") }
                        }
                    }
                    caption("最近动态")
                    card {
                        DisclosureGroup("最近 8 条") {
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
                Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") · 仅本机存储")
                Spacer()
                Button("打开数据目录") { NSWorkspace.shared.open(store.root) }.buttonStyle(.plain)
                Button("完成") { onClose() }.keyboardShortcut(.defaultAction).controlSize(.small)
            }.font(.system(size: 10, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 400, height: store.settingsHeight)
        .foregroundStyle(Color(white: 0.12))
        .background(Color(white: 0.97))
        .preferredColorScheme(.light)
    }
    private func latestAnnouncement(_ post: ResetAnnouncement) -> String {
        let when = post.isUpcoming(at: store.now) ? post.timing?.describe(now: store.now) : post.date?.formatted(date: .abbreviated, time: .shortened)
        let refreshed = post.kind == "possible_reset" ? "" : " · 已刷新 \(store.resetMonitor.refreshedAccountIDs.count)/\(store.resetMonitor.targetCount)"
        return "最近：" + post.label + (when.map { " · " + $0 } ?? "") + refreshed
    }
    private var routing: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(store.gatewayEnabled ? (store.gatewayReady ? mint : .orange) : .white.opacity(0.3)).frame(width: 5, height: 5)
                Text("自动账号路由").font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle("自动账号路由", isOn: Binding(get: { store.gatewayEnabled }, set: { store.setGatewayEnabled($0) }))
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
                    Text("新会话优先").font(.system(size: 12))
                    Spacer()
                    Picker("新会话优先", selection: Binding(get: { store.gatewayPreferred }, set: store.selectGatewayAccount)) {
                        Text("自动选择").tag("")
                        ForEach(store.saved.accounts) { Text($0.displayName).tag($0.id) }
                    }.pickerStyle(.menu).labelsHidden().fixedSize()
                }.padding(.vertical, 6)
                if !store.gatewayReady {
                    Button("重试启动网关") { store.setGatewayEnabled(true) }.controlSize(.small).padding(.bottom, 8)
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
            Text(title).font(.system(size: 12, weight: .medium))
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
        case .personalX: return "登录 X · Tibo 重置提醒"
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
