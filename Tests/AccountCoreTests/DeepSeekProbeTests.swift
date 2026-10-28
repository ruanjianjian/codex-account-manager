import XCTest
@testable import AccountCore

final class DeepSeekProbeTests: XCTestCase {
    let older = "2000000000000000001"
    let newer = "2001000000000000001"
    func url(_ id: String) -> String { "https://x.com/thsottiaux/status/\(id)" }

    func testFixedEndpointAndSecretInHeaderOnly() throws {
        let request = try DeepSeekProbe.request(key: " secret-test ", url: DeepSeekProbe.profileURL)
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/v1/tools/fetch")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-test")
        let body = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(body, ["url": "https://x.com/thsottiaux"])
        for invalid in ["", "  ", "hello\nworld", "hello world", "中文", "abc\rHeader:evil"] {
            XCTAssertThrowsError(try DeepSeekProbe.validatedKey(invalid))
        }
    }
    func testLinksRequireTiboAndSortByIDNotPinnedPageOrder() {
        let text = "[pinned](\(url(older))) [other](https://x.com/other/status/\(newer)) [new](\(url(newer))?s=20) \(url(older))"
        XCTAssertEqual(TiboPostLink.extract(from: text, now: Date()).map(\.id), [newer, older])
        for invalid in ["https://x.com.evil/thsottiaux/status/\(newer)", "https://evil@x.com/thsottiaux/status/\(newer)", "https://x.com:443/thsottiaux/status/\(newer)", "http://x.com/thsottiaux/status/\(newer)", "https://x.com/other/status/\(newer)", "https://x.com/thsottiaux/status/\(newer)/photo/1"] {
            XCTAssertNil(TiboPostLink.parse(invalid))
        }
        XCTAssertTrue(TiboPostLink.extract(from: url("18446744073709551615"), now: Date()).isEmpty)
    }
    func testErrorAndEmptyBodyNeverReportedAsSuccessAndSecretsRedacted() throws {
        let data = try JSONEncoder().encode(FetchedPage(title: "secret-test", content: "hello secret-test"))
        let page = try DeepSeekProbe.decode(data, status: 200, key: "secret-test")
        XCTAssertEqual(page.title, "[REDACTED]")
        XCTAssertEqual(page.content, "hello [REDACTED]")
        for code in [301, 401, 402, 403, 404, 429, 500] {
            XCTAssertThrowsError(try DeepSeekProbe.decode(data, status: code, key: "secret-test")) {
                XCTAssertEqual($0 as? DeepSeekProbeError, .http(code))
                XCTAssertFalse($0.localizedDescription.contains("secret-test"))
            }
        }
        XCTAssertThrowsError(try DeepSeekProbe.decode(Data(#"{"title":"Sign in","content":" "}"#.utf8), status: 200, key: "secret-test"))
        XCTAssertThrowsError(try DeepSeekProbe.decode(Data("not-json".utf8), status: 200, key: "secret-test"))
    }
    func testLoginWallWithHTTP200DoesNotClaimLatestPost() async throws {
        var calls = [URL]()
        let result = try await DeepSeekProbe.probe(reference: nil) { url in
            calls.append(url); return FetchedPage(title: "X", content: "Sign in to X")
        }
        XCTAssertEqual(calls, [DeepSeekProbe.profileURL])
        XCTAssertTrue(result.posts.isEmpty); XCTAssertNil(result.detail)
        XCTAssertTrue(result.summary.contains("尚不能"))
    }
    func testFetchesNewestVisibleDetailOnlyAndDoesNotCertifyFreshness() async throws {
        var calls = [URL]()
        let result = try await DeepSeekProbe.probe(reference: nil) { link in
            calls.append(link)
            return FetchedPage(title: "Tibo", content: link == DeepSeekProbe.profileURL ? "\(self.url(self.older)) \(self.url(self.newer))" : "Post body")
        }
        XCTAssertEqual(calls.map(\.absoluteString), [DeepSeekProbe.profileURL.absoluteString, url(newer)])
        XCTAssertNotNil(result.detail); XCTAssertTrue(result.summary.contains("仍需"))
    }
    func testReferenceMissingFromProfileAndDetailFailurePreserveEvidence() async throws {
        let reference = try XCTUnwrap(TiboPostLink.parse(url(newer)))
        var calls = 0
        let result = try await DeepSeekProbe.probe(reference: reference) { link in
            calls += 1
            if link == DeepSeekProbe.profileURL { return FetchedPage(title: "Tibo", content: self.url(self.older)) }
            throw DeepSeekProbeError.http(404)
        }
        XCTAssertEqual(calls, 2); XCTAssertNil(result.detail)
        XCTAssertTrue(result.summary.contains("未包含"))
        XCTAssertTrue(result.detailError?.contains("404") == true)
        XCTAssertEqual(result.profile.content, url(older))
    }
    func testCancellationStopsBeforeAnotherFetch() async {
        do {
            _ = try await DeepSeekProbe.probe(reference: nil) { _ in throw CancellationError() }
            XCTFail("Cancelled probe must not return success")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}
