import XCTest
@testable import AFMC

@MainActor
final class AFMCTests: XCTestCase {
    private let hashA = String(repeating: "a", count: 40)
    private let hashB = String(repeating: "b", count: 40)

    func testUploadDateAndContentYearAreSeparateAndUnknownDatesSortLast() {
        let model = AppModel()
        model.query = "蜘蛛侠"
        let oldMovieNewUpload = SearchResult(title: "蜘蛛侠 2002 1080p", source: "test", published: Date().addingTimeInterval(-100))
        let newMovieOldUpload = SearchResult(title: "蜘蛛侠 2023 1080p", source: "test", published: Date().addingTimeInterval(-10000))
        let unknown = SearchResult(title: "蜘蛛侠", source: "test")
        let invalid = SearchResult(title: "蜘蛛侠合集 2002-2023", source: "test", published: .distantFuture)
        model.results = [unknown, oldMovieNewUpload, invalid, newMovieOldUpload]
        model.sortOption = .year
        XCTAssertEqual(model.displayedResults.prefix(2).map(\.id), [newMovieOldUpload.id, oldMovieNewUpload.id])
        XCTAssertNil(invalid.contentYear)
        model.sortOption = .newest
        XCTAssertEqual(model.displayedResults.prefix(2).map(\.id), [oldMovieNewUpload.id, newMovieOldUpload.id])
        XCTAssertTrue(model.sortNotice?.contains("2 条日期未知") == true)
        XCTAssertEqual(SearchResult(title: "蜘蛛侠2023年", source: "test").contentYear, 2023)
        XCTAssertNil(SearchResult(title: "蜘蛛侠 2160p", source: "test").contentYear)
        let archive = SearchResult(title: "无年份标题", source: "Internet Archive", releaseYear: 2002)
        XCTAssertEqual(archive.contentYear, 2002)
        XCTAssertNil(archive.uploadDate)
    }

    func testVerifiedSortWithoutEvidenceMatchesRecommendationAndExplainsWhy() {
        let model = AppModel()
        model.query = "蜘蛛侠"
        model.results = [SearchResult(title: "蜘蛛侠 2002", source: "test", seeders: 3),
                         SearchResult(title: "蜘蛛侠 2023 国语", source: "磁力熊", seeders: 1)]
        let recommended = model.displayedResults.map(\.id)
        model.sortOption = .verified
        XCTAssertEqual(model.displayedResults.map(\.id), recommended)
        XCTAssertEqual(model.sortNotice, "当前没有已验证资源，暂按推荐排序")
    }

    func testChinesePreferenceToggleChangesActualRecommendedOrder() {
        let model = AppModel()
        let preference = model.preferChineseResults
        defer { model.preferChineseResults = preference }
        let chinese = SearchResult(title: "Sintel 2010 1080p", source: "磁力熊", seeders: 1)
        let other = SearchResult(title: "Sintel 2010 1080p", source: "other", seeders: 1000)
        model.query = "Sintel"
        model.results = [other, chinese]
        model.sortOption = .relevance
        model.preferChineseResults = false
        XCTAssertEqual(model.displayedResults.first?.id, other.id)
        model.preferChineseResults = true
        XCTAssertEqual(model.displayedResults.first?.id, chinese.id)
        model.sortOption = .seeders
        XCTAssertEqual(model.displayedResults.first?.id, other.id)
        model.sortOption = .relevance
        model.query = "Sintel 英语"
        XCTAssertEqual(model.displayedResults.first?.id, other.id)
    }

    func testSortingInteractionTiming() {
        let model = AppModel()
        model.query = "蜘蛛侠"
        model.results = (0..<200).map { i in
            SearchResult(title: "蜘蛛侠 \(2000 + i % 25) 国英双语 中文字幕 1080p WEB-DL H264 版本\(i)",
                         source: "磁力熊", hash: String(format: "%040x", i + 1), seeders: i)
        }
        let start = Date()
        _ = model.groupedResults
        let warm = Date()
        model.sortOption = .verified
        XCTAssertEqual(model.displayedResults.count, 200)
        _ = model.groupedResults
        let switched = Date()
        XCTAssertLessThan(switched.timeIntervalSince(warm), 0.25, "Switching sort must reuse prepared title analysis")
        for _ in 0..<5 { _ = model.displayedResults; _ = model.groupedResults }
        print("SORT_TIMING cold=\(warm.timeIntervalSince(start)) switch=\(switched.timeIntervalSince(warm)) redraw5=\(Date().timeIntervalSince(switched))")
    }

    func testPresentationCacheRefreshesForEvidenceFiltersAndReplacement() {
        let model = AppModel()
        model.query = "蜘蛛侠"
        let movie = SearchResult(title: "蜘蛛侠 2023 1080p", source: "test", hash: hashA, category: "影视")
        let other = SearchResult(title: "蜘蛛侠 2023 1080p 版本二", source: "test", hash: hashB, category: "影视")
        defer { EvidenceStore.clear(hashA); EvidenceStore.clear(hashB) }
        EvidenceStore.clear(hashA); EvidenceStore.clear(hashB)
        model.results = [movie, other]
        model.sortOption = .verified
        _ = model.groupedResults
        EvidenceStore.markVerified(hashB)
        XCTAssertEqual(model.displayedResults.first?.hash, hashB)
        EvidenceStore.clear(hashB)
        EvidenceStore.markVerified(hashA)
        XCTAssertEqual(model.displayedResults.first?.hash, hashA)
        model.categoryFilter = "书籍"
        XCTAssertTrue(model.displayedResults.isEmpty)
        XCTAssertTrue(model.groupedResults.isEmpty)
        model.categoryFilter = "全部"
        model.results = [other]
        XCTAssertEqual(model.displayedResults.map(\.id), [other.id])
        XCTAssertEqual(model.groupedResults.flatMap(\.results).map(\.id), [other.id])
    }

    func testChinesePreferenceDoesNotOverridePlaybackHealthOrExplicitLanguage() {
        let chinese = SearchResult(title: "Sintel 2010 国语 中文字幕 1080p", source: "磁力熊", hash: "cn-test")
        let english = SearchResult(title: "Sintel 2010 1080p", source: "other", hash: "en-test")
        XCTAssertGreaterThan(SearchQuality.chinesePreference("Sintel", chinese), SearchQuality.chinesePreference("Sintel", english))
        XCTAssertEqual(SearchQuality.chinesePreference("Sintel 英语", chinese), 0)
        let model = AppModel()
        model.query = "Sintel"
        model.results = [chinese, english]
        EvidenceStore.record("cn-test", state: "failed")
        defer { EvidenceStore.clear("cn-test"); EvidenceStore.clear("en-test") }
        XCTAssertEqual(model.displayedResults.first?.hash, "en-test")
    }

    func testUploaderPrefixDoesNotMergeDifferentFilms() {
        let first = SearchResult(title: "【高清影视之家发布 www.HDBTHD.com】蜘蛛侠 2023 1080p", source: "one", category: "影视")
        let second = SearchResult(title: "【高清影视之家发布 www.HDBTHD.com】流浪地球 2023 1080p", source: "one", category: "影视")
        XCTAssertEqual(SearchQuality.displayTitle(first.title), "蜘蛛侠 2023 1080p")
        XCTAssertTrue(Set(SearchQuality.workKeys(first)).isDisjoint(with: SearchQuality.workKeys(second)))
        XCTAssertEqual(SearchQuality.displayTitle("[REC] 2007"), "[REC] 2007")
    }

    func testRecentPlaybackFailureDemotesHighSeedResult() {
        let model = AppModel()
        let failed = String(repeating: "c", count: 40)
        let unknown = String(repeating: "d", count: 40)
        defer { EvidenceStore.clear(failed); EvidenceStore.clear(unknown) }
        model.query = "Sintel"
        model.results = [SearchResult(title: "Sintel 2010 1080p", source: "one", hash: failed, seeders: 999),
                         SearchResult(title: "Sintel 2010 1080p", source: "two", hash: unknown, seeders: 5)]
        EvidenceStore.record(failed, state: "failed")
        XCTAssertEqual(model.displayedResults.first?.hash, unknown)
        EvidenceStore.markVerified(failed)
        XCTAssertEqual(model.displayedResults.first?.hash, failed)
    }

    func testDecodedFrameDoesNotMeanVerifiedPlayback() {
        let key = "unit-decoded-only"
        defer { EvidenceStore.clear(key) }
        EvidenceStore.record(key, state: "decoded", seconds: 2.0)
        XCTAssertFalse(EvidenceStore.isVerified(key))
        XCTAssertEqual(EvidenceStore.tier(key), 1)
    }

    func testHTMLReturnsAllCaptureGroupsForCilixiong() {
        let hash = String(repeating: "a", count: 40)
        let page = "<a href=\"magnet:?xt=urn:btih:\(hash)\">1080p [2.5GB]</a>"
        let anchor = HTML.first(#"<a[^>]*href="(magnet:[^"]+)"[^>]*>(.*?)</a>"#, in: page)
        XCTAssertEqual(anchor?.count, 3)
        XCTAssertEqual(anchor?.last, "1080p [2.5GB]")
        let size = HTML.first(#"\[(\d+(?:\.\d+)?)\s*([GMT])(?:i?B)?\]"#, in: anchor?.last ?? "")
        XCTAssertEqual(size, ["[2.5GB]", "2.5", "G"])
        XCTAssertEqual(HTML.first("(a)(b)?", in: "a"), ["a", "a", ""])
    }

    func testResolveUsesAddedHashAndNeverListsOtherTorrents() async throws {
        var requests: [String] = []
        MockURLProtocol.handler = { request in
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(buffer, count: count)
                }
            }
            let payload = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
            let action = payload["action"] as! String
            requests.append(action)
            var object: [String: Any] = ["hash": String(repeating: "b", count: 40)]
            if action == "get" {
                XCTAssertEqual(payload["hash"] as? String, String(repeating: "b", count: 40))
                object["file_stats"] = [["id": 2, "path": "B.mp4", "length": 200]]
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try! JSONSerialization.data(withJSONObject: object))
        }
        defer { MockURLProtocol.handler = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let source = try await EngineClient.resolve(link: "https://example.com/B.torrent",
            baseURL: URL(string: "http://mock.local")!, session: URLSession(configuration: config))
        XCTAssertEqual(source.url.path, "/play/\(hashB)/2")
        XCTAssertEqual(requests, ["add", "get"])
    }

    func testPlaybackRejectsWrongTorrentAndRetainsEpisodes() throws {
        let torrent: [String: Any] = ["hash": hashB, "file_stats": [
            ["id": 1, "path": "Show.E02.mp4", "length": 900],
            ["id": 2, "path": "Show.E01.mp4", "length": 100],
            ["id": 3, "path": "Show.en.srt", "length": 10]]]
        let base = URL(string: "http://localhost:8099")!
        XCTAssertThrowsError(try EngineClient.playbackSource(torrent: torrent, expectedHash: hashA, baseURL: base))
        let source = try XCTUnwrap(EngineClient.playbackSource(torrent: torrent, expectedHash: hashB, baseURL: base))
        XCTAssertEqual(source.files.map(\.id), [2, 1])
        XCTAssertEqual(source.subtitles.count, 1)
        XCTAssertTrue(source.files.allSatisfy { $0.url.path.hasPrefix("/play/\(hashB)/") })
    }

    func testResolvePropagatesAddFailure() async throws {
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data("bad torrent".utf8))
        }
        defer { MockURLProtocol.handler = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        do {
            _ = try await EngineClient.resolve(link: "invalid", baseURL: URL(string: "http://mock.local")!,
                                               session: URLSession(configuration: config))
            XCTFail("Failed add must not fall back to an old torrent")
        } catch { XCTAssertTrue(error.localizedDescription.contains("400")) }
    }

    func testConcurrentBrowserLoadsAreIsolated() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("a.html")
        let b = folder.appendingPathComponent("b.html")
        try "<html><body><script>document.body.textContent='SOURCE_A'</script></body></html>".write(to: a, atomically: true, encoding: .utf8)
        try "<html><body><script>document.body.textContent='SOURCE_B'</script></body></html>".write(to: b, atomically: true, encoding: .utf8)
        async let first = BrowserPageLoader.shared.loadHTML(a, settle: 0.1)
        async let second = BrowserPageLoader.shared.loadHTML(b, settle: 0.1)
        let results = try await (first, second)
        XCTAssertTrue(results.0.contains("SOURCE_A"))
        XCTAssertTrue(results.1.contains("SOURCE_B"))
        let third = try await BrowserPageLoader.shared.loadHTML(a, settle: 0.2)
        XCTAssertTrue(third.contains("SOURCE_A"))
    }

    func testWebsiteTitlesStayWithTheirOwnRows() throws {
        let html = """
        <table>
        <tr><td><a href='/view/1'>Sintel 720p</a></td><td><a href='magnet:?xt=urn:btih:\(hashA)'>MAGNET</a></td></tr>
        <tr><td><a href='/view/2'>Sintel 1080p</a></td><td><a href='magnet:?xt=urn:btih:\(hashB)'>MAGNET</a></td></tr>
        </table>
        """
        let rows = try SearchSourceClient.parseWebsite(html, source: "fixture", url: URL(string: "https://example.com/search")!)
        XCTAssertEqual(rows.map(\.title), ["Sintel 720p", "Sintel 1080p"])
        XCTAssertEqual(rows.map(\.hash), [hashA, hashB])
        XCTAssertEqual(rows.last?.detailsURL, "https://example.com/view/2")
    }

    func testMagnetHash() {
        let magnet = "magnet:?xt=urn:btih:\(hashA.uppercased())&dn=Demo"
        XCTAssertEqual(Links.magnetHash(magnet), hashA)
        XCTAssertNil(Links.magnetHash("magnet:?xt=urn:btih:short"))
        XCTAssertNil(Links.magnetHash(nil))
    }

    func testMagnetBase32AndExactParameterValidation() {
        XCTAssertEqual(Links.magnetHash("magnet:?xt=urn%3Abtih%3A" + String(repeating: "A", count: 32)), String(repeating: "0", count: 40))
        XCTAssertNil(Links.magnetHash("https://example.com/?xt=urn:btih:" + hashA))
        XCTAssertNil(Links.magnetHash("magnet:?dn=urn:btih:" + hashA))
        XCTAssertNil(Links.magnetHash("magnet:?xt=urn:btih:" + hashA + "00"))
    }

    func testMagnetLinkFallsBackToHash() {
        let result = SearchResult(title: "x", source: "s", hash: hashA)
        XCTAssertEqual(Links.magnetLink(for: result), "magnet:?xt=urn:btih:\(hashA)")
    }

    func testDeduplicateKeepsHighestSeeders() {
        let low = SearchResult(title: "low", source: "s1", hash: hashA, seeders: 5)
        let high = SearchResult(title: "high", source: "s2", hash: hashA, seeders: 50)
        let other = SearchResult(title: "other", source: "s3", hash: hashB, seeders: 1)
        let output = AppModel.deduplicate([low, high, other])
        XCTAssertEqual(output.count, 2)
        XCTAssertEqual(output.first?.title, "high")
    }

    func testSortBySizeAndCategoryFilter() {
        let model = AppModel()
        model.results = [
            SearchResult(title: "small", source: "s", size: 100, seeders: 1, category: "视频"),
            SearchResult(title: "big", source: "s", size: 900, seeders: 3, category: "音频"),
        ]
        model.sortOption = .size
        XCTAssertEqual(model.displayedResults.map(\.title), ["big", "small"])

        model.categoryFilter = "影视"
        XCTAssertEqual(model.displayedResults.map(\.title), ["small"])
    }

    func testTorznabParsing() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:torznab="http://torznab.com/schemas/2015/feed">
        <channel>
        <item>
          <title>Mock Movie 2024</title>
          <guid>https://example.com/1</guid>
          <link>magnet:?xt=urn:btih:\(hashA)&amp;dn=Mock</link>
          <pubDate>Fri, 07 Nov 2025 10:00:00 +0000</pubDate>
          <torznab:attr name="seeders" value="42"/>
          <torznab:attr name="category" value="Movies"/>
          <torznab:size>1234567890</torznab:size>
        </item>
        <item>
          <title>Mock Show S01E01</title>
          <guid>https://example.com/2</guid>
          <link>magnet:?xt=urn:btih:\(hashB)&amp;dn=Show</link>
          <torznab:attr name="seeders" value="7"/>
        </item>
        </channel>
        </rss>
        """
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(xml.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let config = SourceConfig(name: "mock", kind: .torznab,
                                  endpoint: "http://mock.local/torznab")
        let results = try await TorznabSource.search(config, query: "mock", session: session)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first?.seeders, 42)
        XCTAssertEqual(results.first?.size, 1_234_567_890)
        XCTAssertEqual(results.first?.category, "Movies")
        XCTAssertEqual(results.first?.magnet, "magnet:?xt=urn:btih:\(hashA)&dn=Mock")
    }

    func testDefaultSortIsSeeders() {
        let model = AppModel()
        model.results = [
            SearchResult(title: "low", source: "s", seeders: 1),
            SearchResult(title: "high", source: "s", seeders: 9),
        ]
        model.sortOption = .seeders
        XCTAssertEqual(model.displayedResults.map(\.title), ["high", "low"])
    }

    func testGroupingByWorkKey() {
        let model = AppModel()
        model.results = [
            SearchResult(title: "Sintel.2010.1080p.mkv", source: "s", hash: hashA),
            SearchResult(title: "Sintel.2010.720p.mkv", source: "s", hash: hashB),
            SearchResult(title: "Other Thing", source: "s"),
        ]
        XCTAssertEqual(model.groupedResults.count, 2)
        XCTAssertEqual(model.groupedResults.first(where: { $0.id == "2010::sintel" })?.results.count, 2)
    }

    func testSubtitleParserAndStore() {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nHello\n\n2\n00:00:03,500 --> 00:00:04,000\nWorld\n"
        let cues = SubtitleParser.parse(srt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues.first?.text, "Hello")
        XCTAssertEqual(cues.first?.start ?? 0, 1.0, accuracy: 0.01)
        SubtitleStore.save(Data(srt.utf8), for: "unit-sub")
        XCTAssertNotNil(SubtitleStore.load("unit-sub"))
        SubtitleStore.clear("unit-sub")
        XCTAssertNil(SubtitleStore.load("unit-sub"))
    }

    func testEvidenceStore() {
        let key = "unit-evidence"
        EvidenceStore.markVerified(key)
        XCTAssertTrue(EvidenceStore.isVerified(key))
        XCTAssertNotNil(EvidenceStore.date(key))
        EvidenceStore.clear(key)
        XCTAssertFalse(EvidenceStore.isVerified(key))
    }

    func testWebsiteDiscoveryParse() {
        let html = #"<form action="/search" method="get"><input type="text" name="q"></form>"#
        let candidates = WebsiteDiscovery.parse(html: html, baseURL: URL(string: "https://example.com")!)
        XCTAssertEqual(candidates.first?.template, "https://example.com/search?q={q}")
    }

    func testProgressStore() {
        ProgressStore.save("unit-test", 42.5)
        XCTAssertEqual(ProgressStore.load("unit-test"), 42.5)
        ProgressStore.clear("unit-test")
        XCTAssertNil(ProgressStore.load("unit-test"))
    }

    func testSearchQualityCanonical() {
        let value = SearchQuality.canonical("Spider-Man 4K 2019 第2季")
        XCTAssertTrue(value.contains("2160p"))
        XCTAssertTrue(value.contains("2019"))
        XCTAssertTrue(value.contains("s02"))
    }

    func testSearchQualityCategory() {
        let movie = SearchResult(title: "Movie.2024.1080p.BluRay.x264.mkv", source: "s", category: "视频")
        XCTAssertEqual(SearchQuality.category(movie), "影视")
        let book = SearchResult(title: "Some Book.epub", source: "s", category: "未知")
        XCTAssertEqual(SearchQuality.category(book), "书籍")
    }

    func testSearchQualityTierAndSummary() {
        XCTAssertEqual(SearchQuality.matchTier("sintel", "Sintel.2010.1080p.BluRay.x264"), 0)
        XCTAssertEqual(SearchQuality.matchTier("zzz", "Sintel.2010.1080p"), 3)
        let summary = SearchQuality.technicalSummary(SearchResult(title: "Sintel 1080p x264", source: "s"))
        XCTAssertTrue(summary.contains("1080p"))
        XCTAssertTrue(summary.contains("x264"))
    }
}


final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else { return }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
