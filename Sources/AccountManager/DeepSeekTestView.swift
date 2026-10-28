import SwiftUI
import AccountCore

struct DeepSeekTestView: View {
    @ObservedObject var store: AppStore
    let onClose: () -> Void
    @State private var key = ""
    @State private var referenceURL = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Tibo 直连测试").font(.title2.weight(.semibold))
                Spacer()
                Button("完成", action: onClose)
            }
            Text("用 DeepSeek Fetch 读取 Tibo 的 X 主页，再读取一个帖子。仅手动测试，尚未接入自动刷新。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField(store.deepSeekHasKey ? "已在本次运行中保留 Key；可填入新 Key" : "DeepSeek API Key", text: $key)
                .textFieldStyle(.roundedBorder).accessibilityLabel("DeepSeek API Key")
                .disabled(store.deepSeekTesting)
            Text("Key 只在本次运行中保留，退出即清除；仅发给 api.deepseek.com，不写入文件或钥匙串。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("对照最新帖子（可选）") {
                TextField("https://x.com/thsottiaux/status/…", text: $referenceURL)
                    .textFieldStyle(.roundedBorder).disabled(store.deepSeekTesting)
                Text("填入你在 X 看到的最新原帖，检查主页抓取是否包含它。未填写时读取主页中 ID 最新的帖子。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(store.deepSeekTesting ? "正在抓取…" : "测试抓取 Tibo") {
                    store.testDeepSeek(key: key, referenceURL: referenceURL); key = ""
                }.buttonStyle(.borderedProminent)
                    .disabled(store.preview || store.deepSeekTesting || (key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.deepSeekHasKey))
                if store.deepSeekTesting { Button("取消测试") { store.cancelDeepSeekTest() } }
                Spacer()
                Button("清除 Key") { key = ""; store.clearDeepSeekKey() }.disabled(!store.deepSeekHasKey && key.isEmpty)
            }
            Text("每次最多 2 次抓取；成功请求可能按 DeepSeek 价格计费。不会自动重试。")
                .font(.caption).foregroundStyle(.secondary)
            if let error = store.deepSeekError {
                Text(error).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let result = store.deepSeekResult {
                        Text(result.summary).font(.headline).fixedSize(horizontal: false, vertical: true)
                        Text("本次抓取：" + result.checkedAt.formatted(date: .abbreviated, time: .standard))
                            .font(.caption).foregroundStyle(.secondary)
                        if let error = result.detailError { Text("帖子页面：" + error).font(.caption).foregroundStyle(.orange) }
                        ForEach(result.posts.prefix(5)) { post in
                            VStack(alignment: .leading, spacing: 2) {
                                Link("Tibo 原帖 · \(post.id)", destination: post.url).font(.caption)
                                if let date = post.estimatedDate {
                                    Text("发布时间（由帖子 ID 推算）：" + date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if let target = result.detailTarget { Link("打开本次核验的帖子", destination: target.url).font(.caption) }
                        if let detail = result.detail {
                            Text("帖子页面返回内容").font(.headline)
                            Text(verbatim: detail.content).font(.system(size: 12)).textSelection(.enabled)
                        }
                        DisclosureGroup("查看主页返回内容") {
                            Text(verbatim: result.profile.content).font(.system(size: 12)).textSelection(.enabled)
                        }
                    } else {
                        Text(store.deepSeekTesting ? "正在读取 X 页面，通常需要数秒，最多约 80 秒。" : "填写 Key 后点击测试。抓到页面不代表抓到了最新帖子，结果会保留在这里供核对。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
            HStack {
                Link("打开 Tibo 的 X", destination: DeepSeekProbe.profileURL)
                Spacer()
                Link("DeepSeek 接口与价格", destination: URL(string: "https://api-docs.deepseek.com/guides/search/")!)
            }.font(.caption)
        }.padding(24).frame(width: 500, height: min(700, (NSScreen.main?.visibleFrame.height ?? 800) - 120))
        .onDisappear { key = "" }
    }
}
