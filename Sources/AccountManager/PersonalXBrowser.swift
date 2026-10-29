import AppKit
import WebKit
import SwiftUI
import AccountCore

/// Personal, app-owned WebKit session. No cookie exports, shared credentials or browser profile copying.
@MainActor final class PersonalXBrowser: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var interactive = false
    private var fetching = false
    private var navigationFinished = false
    private var navigationFailed = false
    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }
    func openTibo() {
        guard !fetching else { return }
        navigationFinished = false; navigationFailed = false
        webView.load(URLRequest(url: TiboPostLink.profileURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { navigationFinished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed = true }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { navigationFailed = true }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, ["https", "about"].contains(url.scheme ?? "") else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame != false, url.scheme == "https" {
            let host = url.host?.lowercased() ?? ""
            let xHost = host == "x.com" || host.hasSuffix(".x.com") || host == "twitter.com" || host.hasSuffix(".twitter.com")
            if !xHost { decisionHandler(.cancel); return }
        }
        decisionHandler(.allow)
    }
    func readTimeline(reload: Bool) async throws -> [XVisiblePost] {
        guard !fetching, !reload || !interactive else { throw PersonalXError.busy }
        fetching = true
        defer { fetching = false }
        if reload || webView.url == nil {
            navigationFinished = false; navigationFailed = false
            webView.load(URLRequest(url: TiboPostLink.profileURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        }
        var lastError: Error = PersonalXError.noPosts
        for _ in 0..<30 {
            try await Task.sleep(for: .seconds(1))
            try Task.checkCancellation()
            if navigationFailed { throw PersonalXError.unavailable }
            guard !webView.isLoading, navigationFinished || !reload else { continue }
            do {
                let value = try await webView.evaluateJavaScript(Self.readScript)
                guard let text = value as? String, let data = text.data(using: .utf8), data.count <= 2_000_000 else { throw PersonalXError.noPosts }
                let page = try JSONDecoder().decode(XTimelinePage.self, from: data)
                let posts = try page.validated(at: Date())
                return posts
            } catch PersonalXError.loginRequired { throw PersonalXError.loginRequired }
            catch PersonalXError.wrongPage { throw PersonalXError.wrongPage }
            catch { lastError = PersonalXError.noPosts }
        }
        throw lastError
    }
    func stop() { webView.stopLoading() }
    // Only visible DOM data is read. Nested quoted tweets do not supply the author's identity or announcement.
    private static let readScript = #"""
    (() => {
      const posts = [];
      for (const article of document.querySelectorAll('article[data-testid="tweet"]')) {
        const own = node => {
          if (!node || node.closest('article') !== article) return false;
          // Normal timestamp anchors also have role=link. Only exclude the
          // nested clickable quote container, not the author's own anchor.
          for (let parent = node; parent && parent !== article; parent = parent.parentElement) {
            if (parent.getAttribute('role') === 'link' && parent.tagName !== 'A') return false;
          }
          return true;
        };
        const time = [...article.querySelectorAll('time[datetime]')].find(own);
        const link = time?.closest('a[href]');
        const text = [...article.querySelectorAll('[data-testid="tweetText"]')].find(own);
        if (!time || !link || !text) continue;
        const parsed = new URL(link.href, location.href);
        if (!/^\/thsottiaux\/status\/[0-9]+\/?$/i.test(parsed.pathname)) continue;
        posts.push({url: 'https://x.com' + parsed.pathname, publishedAt: time.getAttribute('datetime'),
          text: text.innerText.slice(0, 20000), truncated: !!article.querySelector('[data-testid="tweet-text-show-more-link"]')});
      }
      return JSON.stringify({pageURL: location.href,
        loggedIn: !!document.querySelector('[data-testid="SideNav_AccountSwitcher_Button"], [data-testid="AppTabBar_Profile_Link"]'),
        posts: posts.slice(0,40)});
    })()
    """#
}

private struct PersonalXWebView: NSViewRepresentable {
    let browser: PersonalXBrowser
    func makeNSView(context: Context) -> WKWebView { browser.webView }
    func updateNSView(_ view: WKWebView, context: Context) { }
}

struct PersonalXLoginView: View {
    @ObservedObject var store: AppStore
    let onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("个人 X · Tibo 监控").font(.headline)
                Spacer()
                Button("打开 Tibo 主页") { store.personalXBrowser.openTibo() }.disabled(store.personalXTesting)
                Button("登录后测试并开启监控") { store.testAndEnablePersonalX() }.disabled(store.personalXTesting)
                Button("完成", action: onClose)
            }.padding(.horizontal, 16).padding(.top, 12)
            Text(store.personalXTesting ? "正在读取主页…" : store.personalXCaption)
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
            Text("使用自己的 X 账号登录一次，登录态由本机浏览器保存。请用邮箱/用户名登录；不支持外部 Google/Apple 登录跳转。成功读取后每分钟检查，关掉此窗口继续运行。")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).fixedSize(horizontal: false, vertical: true)
            PersonalXWebView(browser: store.personalXBrowser)
        }.frame(width: min(1000, (NSScreen.main?.visibleFrame.width ?? 1100) - 80), height: min(780, (NSScreen.main?.visibleFrame.height ?? 900) - 100))
            .onAppear { store.personalXBrowser.interactive = true; if store.personalXBrowser.webView.url == nil { store.personalXBrowser.openTibo() } }
            .onDisappear { store.personalXBrowser.interactive = false }
    }
}
