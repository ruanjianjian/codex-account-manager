import SwiftUI
import AccountCore

/// First-run steps before routing: the desktop's own account (logins are always kept in files). Routing then
/// switches itself on, so there is nothing else to click unless the user had turned it off.
struct RoutingSetupSteps: View {
    @ObservedObject var store: AppStore
    private let mint = Color(red: 0.55, green: 0.96, blue: 0.78)
    var body: some View {
        let setup = store.routingSetup
        VStack(alignment: .leading, spacing: 7) {
            step(1, L("连接 Codex 桌面账号", "Connect the Codex desktop account"), done: setup == .ready, detail: setup == .ready ? desktopName : nil) {
                switch setup {
                case .fileStorage:
                    if store.storageMoveFailed { Button(L("重试", "Retry")) { store.retryFileStorage() }.disabled(store.preview) }
                    else { Text(L("正在准备…", "Preparing…")).foregroundStyle(.white.opacity(0.55)) }
                case .desktopLogin: Text(L("先在 Codex 登录", "Sign in to Codex first")).foregroundStyle(.white.opacity(0.55))
                case .desktopAccount(let email):
                    Button(email.map { L("连接 ", "Connect ") + Presentation.maskedEmail($0) } ?? L("连接", "Connect")) { store.connectDesktopAccount() }
                        .disabled(store.preview || store.loginSlotID != nil)
                default: EmptyView()
                }
            }
            step(2, L("开启路由", "Turn on routing"), done: false) {
                if setup == .ready { Button(L("开启", "Turn on")) { store.setGatewayEnabled(true) }.disabled(store.preview) }
                else { Text(store.routingChoice == false ? L("完成后点开启", "Then click Turn on") : L("完成后自动开启", "Turns on when done")).foregroundStyle(.white.opacity(0.55)) }
            }
        }.font(.system(size: 11)).buttonStyle(.borderless).controlSize(.small)
    }
    private var desktopName: String? {
        store.saved.accounts.first { $0.expectedAccountID == store.desktopAccountID }?.displayName
    }
    private func step<Trailing: View>(_ number: Int, _ title: String, done: Bool, detail: String? = nil,
                                      @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            ZStack {
                if done { Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(mint) }
                else { Text("\(number)").font(.system(size: 9, weight: .bold, design: .monospaced)) }
            }.frame(width: 16, height: 16).background(.white.opacity(done ? 0.08 : 0.16), in: RoundedRectangle(cornerRadius: 3))
            Text(title).foregroundStyle(.white.opacity(done ? 0.55 : 1))
            if let detail { Text(detail).foregroundStyle(.white.opacity(0.45)).lineLimit(1) }
            Spacer(minLength: 6)
            if !done { trailing().tint(mint) }
        }.frame(minHeight: 20)
            .accessibilityElement(children: .contain).accessibilityLabel(L("第 \(number) 步，\(title)\(done ? "，已完成" : "")", "Step \(number), \(title)\(done ? ", done" : "")"))
    }
}

/// Stands where the live routing panel goes while routing is off.
struct RoutingSetupView: View {
    @ObservedObject var store: AppStore
    private let paper = Color(red: 0.065, green: 0.085, blue: 0.105)
    var body: some View {
        let setup = store.routingSetup
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("AUTO ROUTING").font(.system(size: 9, weight: .bold)).tracking(1)
                Spacer(minLength: 3)
                Text(setup == .ready ? L("已关闭", "Off") : L("还差 \(setup.remaining) 步", "\(setup.remaining) step\(setup.remaining == 1 ? "" : "s") left")).font(.system(size: 9)).foregroundStyle(.white.opacity(0.75))
            }
            if setup == .ready {
                HStack {
                    Text(L("开启后，Codex 的请求由 Tibot 自动挑账号", "Once on, Tibot picks the account for each Codex request")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
                    Spacer(minLength: 6)
                    Button(L("开启", "Turn on")) { store.setGatewayEnabled(true) }.buttonStyle(.borderless).controlSize(.small)
                        .tint(Color(red: 0.55, green: 0.96, blue: 0.78)).disabled(store.preview)
                }
            } else {
                RoutingSetupSteps(store: store)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .foregroundStyle(.white).background(paper, in: RoundedRectangle(cornerRadius: 9))
        .environment(\.colorScheme, .dark)
    }
}
