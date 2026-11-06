import Foundation

/// Windows 端内置来源的 Swift 实现（API / RSS 类）。
enum SearchSourceClient {
    static func search(_ source: SourceConfig, query: String) async throws -> [SearchResult] {
        switch source.kind {
        case .piratebay:
            return try await PirateBaySource.search(query: query)
        case .torznab:
            return try await TorznabSource.search(source, query: query)
        case .archive:
            return try await ArchiveSource.search(query: query)
        case .knaben:
            return try await knaben(query)
        case .bitsearch:
            return try await bitSearch(query)
        case .nyaa:
            return try await nyaa(query)
        case .dmhy:
            return try await dmhy(query)
        case .torrentscsv:
            return try await torrentsCSV(query)
        case .tokyotosho:
            return try await tokyoTosho(query)
        case .foss:
            return try await foss(query)
        case .debian:
            return try await SiteSourcesClient.debian(query)
        case .linuxtracker:
            return try await SiteSourcesClient.linuxTracker(query)
        case .limetorrents:
            return try await SiteSourcesClient.limeTorrents(query)
        case .zhongzilou:
            return try await SiteSourcesClient.zhongzilou(query)
        case .tpbproxy:
            return try await SiteSourcesClient.tpbProxy(query)
        case .cilixiong:
            return try await SiteSourcesClient.cilixiong(query)
        case .eztv:
            return try await SiteSourcesClient.eztv(query)
        case .website:
            return try await website(source, query)
        }
    }

    // MARK: - HTTP

    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/xml, application/xml, text/html;q=0.9", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SourceError.http(http.statusCode)
        }
        return data
    }

    // MARK: - Knaben

    private static func knaben(_ query: String) async throws -> [SearchResult] {
        var components = URLComponents(string: "https://api.knaben.org/v2/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "s", value: "100"),
            URLQueryItem(name: "f", value: "0"),
        ]
        let data = try await get(components.url!)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = root["hits"] as? [[String: Any]] else {
            throw SourceError.parse
        }
        return hits.compactMap { item in
            guard let title = item["title"] as? String, !title.isEmpty else { return nil }
            let hash = Links.normalizeHash(item["hash"] as? String)
            let provided = item["magnetUrl"] as? String
            guard let magnet = makeMagnet(hash: hash, title: title, provided: provided) else { return nil }
            let tracker = (item["tracker"] as? String)?.trimmingCharacters(in: .whitespaces)
            let source = tracker?.isEmpty == false ? "Knaben（\(tracker!.prefix(60))）" : "Knaben"
            return SearchResult(
                title: title,
                source: source,
                magnet: magnet,
                torrentURL: nil,
                detailsURL: (item["details"] as? String).flatMap { $0.hasPrefix("https://") ? $0 : nil },
                coverURL: safeCover(item["coverUrl"]) ?? safeCover(item["poster"]) ?? safeCover(item["thumbnail"]),
                archiveId: nil,
                hash: Links.magnetHash(magnet),
                size: int64(item["bytes"]),
                seeders: int(item["seeders"]),
                category: (item["category"] as? String) ?? "未知",
                published: isoDate(item["date"] as? String)
            )
        }
    }

    // MARK: - BitSearch

    private static func bitSearch(_ query: String) async throws -> [SearchResult] {
        var components = URLComponents(string: "https://bitsearch.eu/api/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "sort", value: "relevance"),
            URLQueryItem(name: "page", value: "1"),
        ]
        let data = try await get(components.url!)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else {
            throw SourceError.parse
        }
        return results.compactMap { item in
            guard let title = item["title"] as? String, !title.isEmpty else { return nil }
            let hash = Links.normalizeHash(item["infohash"] as? String)
            guard let magnet = makeMagnet(hash: hash, title: title, provided: item["magnetUrl"] as? String) else { return nil }
            let category = bitSearchCategory(int(item["category"]))
            return SearchResult(
                title: title,
                source: "BitSearch",
                magnet: magnet,
                torrentURL: nil,
                detailsURL: (item["id"]).flatMap { "https://bitsearch.eu/torrent/\($0)" },
                coverURL: nil,
                archiveId: nil,
                hash: Links.magnetHash(magnet),
                size: int64(item["size"]),
                seeders: int(item["seeders"]),
                category: category,
                published: isoDate(item["createdAt"] as? String)
            )
        }
    }

    private static func bitSearchCategory(_ value: Int?) -> String {
        switch value {
        case 1: return "其他"
        case 2: return "电影"
        case 3: return "剧集"
        case 4: return "动漫"
        case 5: return "软件"
        case 6: return "游戏"
        case 7: return "音乐"
        case 8: return "有声书"
        case 9: return "电子书 / 课程"
        case 10: return "成人"
        default: return "未知"
        }
    }

    // MARK: - Nyaa

    private static func nyaa(_ query: String) async throws -> [SearchResult] {
        var components = URLComponents(string: "https://nyaa.si/")!
        components.queryItems = [
            URLQueryItem(name: "page", value: "rss"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "c", value: "0_0"),
            URLQueryItem(name: "f", value: "0"),
        ]
        let data = try await get(components.url!)
        let items = try RSSParser.parse(data)
        return items.compactMap { item in
            guard let title = item["title"], !title.isEmpty,
                  let hash = Links.normalizeHash(item["infoHash"]) else { return nil }
            let magnet = makeMagnet(hash: hash, title: title, provided: nil)
            return SearchResult(
                title: title,
                source: "Nyaa",
                magnet: magnet,
                torrentURL: nil,
                detailsURL: item["guid"].flatMap { $0.hasPrefix("https://nyaa.si/") ? $0 : nil },
                coverURL: nil,
                archiveId: nil,
                hash: hash,
                size: item["size"].flatMap(Self.parseSize),
                seeders: item["seeders"].flatMap(Int.init),
                category: item["category"] ?? "未知",
                published: rssDate(item["pubDate"])
            )
        }
    }

    // MARK: - 动漫花园

    private static func dmhy(_ query: String) async throws -> [SearchResult] {
        var components = URLComponents(string: "https://share.dmhy.org/topics/rss/rss.xml")!
        components.queryItems = [URLQueryItem(name: "keyword", value: query)]
        let data = try await get(components.url!)
        let items = try RSSParser.parse(data)
        return items.compactMap { item in
            guard let title = item["title"], !title.isEmpty,
                  let hash = Links.magnetHash(item["enclosure"]) else { return nil }
            let magnet = "magnet:?xt=urn:btih:\(hash)&dn=\(title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? title)"
            var details = item["link"]
            if let value = details, !value.hasPrefix("https://share.dmhy.org/topics/view/") { details = nil }
            let category = dmhyCategory(item["category"] ?? "")
            return SearchResult(
                title: title,
                source: "动漫花园",
                magnet: magnet,
                torrentURL: nil,
                detailsURL: details,
                coverURL: nil,
                archiveId: nil,
                hash: hash,
                size: nil,
                seeders: nil,
                category: category,
                published: rssDate(item["pubDate"])
            )
        }
    }

    private static func dmhyCategory(_ value: String) -> String {
        switch value {
        case "動畫", "季度全集": return "动漫"
        case "音樂", "動漫音樂", "同人音樂": return "音乐"
        case "漫畫": return "书籍"
        case "遊戲": return "游戏"
        default: return value.isEmpty ? "未知" : value
        }
    }

    // MARK: - Torrents.csv

    private static func torrentsCSV(_ query: String) async throws -> [SearchResult] {
        var components = URLComponents(string: "https://torrents-csv.com/service/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        let data = try await get(components.url!)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["torrents"] as? [[String: Any]] else {
            throw SourceError.parse
        }
        return rows.prefix(100).compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty,
                  let hash = Links.normalizeHash(row["infohash"] as? String) else { return nil }
            return SearchResult(
                title: name,
                source: "Torrents.csv",
                magnet: "magnet:?xt=urn:btih:\(hash)&dn=\(name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name)",
                torrentURL: nil,
                detailsURL: "https://torrents-csv.com/?q=\(name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name)",
                coverURL: nil,
                archiveId: nil,
                hash: hash,
                size: int64(row["size_bytes"]),
                seeders: int(row["seeders"]),
                category: "未知",
                published: int64(row["created_unix"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
        }
    }

    // MARK: - Tokyo Toshokan

    private static func tokyoTosho(_ query: String) async throws -> [SearchResult] {
        var components = URLComponents(string: "https://www.tokyotosho.info/rss.php")!
        components.queryItems = [URLQueryItem(name: "terms", value: query)]
        let data = try await get(components.url!)
        let items = try RSSParser.parse(data)
        return items.compactMap { item in
            guard let title = item["title"], !title.isEmpty,
                  let description = item["description"],
                  let hash = firstMagnetHash(description) else { return nil }
            let magnet = "magnet:?xt=urn:btih:\(hash)&dn=\(title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? title)"
            return SearchResult(
                title: title,
                source: "Tokyo Toshokan",
                magnet: magnet,
                torrentURL: nil,
                detailsURL: item["guid"].flatMap { $0.hasPrefix("https://www.tokyotosho.info/") ? $0 : nil },
                coverURL: nil,
                archiveId: nil,
                hash: hash,
                size: firstSize(description),
                seeders: nil,
                category: item["category"] ?? "未知",
                published: rssDate(item["pubDate"])
            )
        }
    }

    // MARK: - FOSS Torrents

    private static func foss(_ query: String) async throws -> [SearchResult] {
        let data = try await get(URL(string: "https://fosstorrents.com/feed/torrents.xml")!)
        let items = try RSSParser.parse(data)
        let terms = SearchQuality.canonical(query).split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }
        return items.compactMap { item in
            guard let title = item["title"], !title.isEmpty,
                  let link = item["link"], link.hasPrefix("https://fosstorrents.com/direct-files/"),
                  link.hasSuffix(".torrent") else { return nil }
            let canonicalTitle = SearchQuality.canonical(title)
            guard terms.allSatisfy({ canonicalTitle.contains($0) }) else { return nil }
            return SearchResult(
                title: title,
                source: "FOSS Torrents",
                magnet: nil,
                torrentURL: link,
                detailsURL: "https://fosstorrents.com/",
                coverURL: nil,
                archiveId: nil,
                hash: nil,
                size: nil,
                seeders: nil,
                category: "软件",
                published: rssDate(item["pubDate"])
            )
        }
    }

    // MARK: - Debian

    private static func debian() async throws -> [SearchResult] {
        let data = try await get(URL(string: "https://www.debian.org/CD/torrent-cd/")!)
        guard let html = String(data: data, encoding: .utf8) else { throw SourceError.parse }
        let regex = try NSRegularExpression(pattern: #"href="([^"]+\.torrent)""#, options: [.caseInsensitive])
        var seen = Set<String>()
        var results: [SearchResult] = []
        let range = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, range: range) {
            guard let r = Range(match.range(at: 1), in: html) else { continue }
            var path = String(html[r])
            if path.hasPrefix("/") { path = "https://www.debian.org" + path }
            guard path.hasPrefix("https://"), seen.insert(path).inserted else { continue }
            let name = path.split(separator: "/").last.map(String.init) ?? path
            results.append(SearchResult(
                title: name.replacingOccurrences(of: ".torrent", with: ""),
                source: "Debian 官方",
                magnet: nil,
                torrentURL: path,
                detailsURL: "https://www.debian.org/CD/torrent-cd/",
                coverURL: nil,
                archiveId: nil,
                hash: nil,
                size: nil,
                seeders: nil,
                category: "软件",
                published: nil
            ))
        }
        return results
    }

    // MARK: - 网页磁力源（自定义搜索地址模板）

    private static func website(_ source: SourceConfig, _ query: String) async throws -> [SearchResult] {
        let template = source.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard template.contains("{q}") || template.contains("{query}") else {
            throw SourceError.badEndpoint
        }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        let text = template
            .replacingOccurrences(of: "{query}", with: encoded)
            .replacingOccurrences(of: "{q}", with: encoded)
        guard let url = URL(string: text) else { throw SourceError.badEndpoint }
        let html: String
        if source.useBrowser {
            html = try await BrowserPageLoader.shared.loadHTML(url)
        } else {
            html = String(decoding: try await get(url), as: UTF8.self)
        }
        return try parseWebsite(html, source: source.name, url: url)
    }

    static func parseWebsite(_ html: String, source: String, url: URL) throws -> [SearchResult] {
        let anchorPattern = #"<a\b[^>]*href\s*=\s*["'](magnet:[^"']+)["'][^>]*>(.*?)</a>"#
        // Match explicit result rows; never borrow a title from neighbouring resources.
        let rows = HTML.matches(#"<(tr|li|article)\b[^>]*>(.*?)</\1\s*>"#, in: html, groups: 2).map { $0[0] }
        var results: [SearchResult] = []
        var seen = Set<String>()
        for anchor in HTML.matches(anchorPattern, in: html, groups: 2) {
            let magnet = HTML.decode(anchor[1])
            guard let hash = Links.magnetHash(magnet), seen.insert(hash).inserted else { continue }
            func usable(_ text: String) -> Bool {
                let lower = text.lowercased()
                return text.count >= 3 && !["magnet", "download", "下载", "磁力", "磁力链接", "种子下载"].contains(lower)
            }
            var title = HTML.strip(anchor[2])
            var detail = url.absoluteString
            if !usable(title) {
                if let row = rows.first(where: { $0.contains(anchor[0]) }) {
                    for link in HTML.matches(#"<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#, in: row, groups: 2) {
                        let label = HTML.strip(link[2])
                        guard !link[1].lowercased().hasPrefix("magnet:"), usable(label),
                              let target = URL(string: HTML.decode(link[1]), relativeTo: url)?.absoluteURL,
                              ["http", "https"].contains(target.scheme?.lowercased() ?? "") else { continue }
                        title = label
                        detail = target.absoluteString
                        break
                    }
                }
                if !usable(title), let name = URLComponents(string: magnet)?.queryItems?.first(where: { $0.name == "dn" })?.value {
                    title = name.replacingOccurrences(of: "+", with: " ")
                }
            }
            results.append(SearchResult(title: usable(title) ? title : "磁力资源 \(hash.prefix(8))",
                                        source: source, magnet: magnet, detailsURL: detail, hash: hash,
                                        category: "未知"))
            if results.count >= 100 { break }
        }
        if results.isEmpty && !html.contains("没有找到") && !html.localizedCaseInsensitiveContains("no results") {
            throw SourceError.parse
        }
        return results
    }

    // MARK: - 工具

    private static func makeMagnet(hash: String?, title: String, provided: String?) -> String? {
        let normalized = Links.normalizeHash(hash)
        let providedHash = Links.magnetHash(provided)
        if let normalized, let providedHash, normalized != providedHash { return nil }
        if providedHash != nil, let provided { return provided }
        guard let normalized else { return nil }
        return "magnet:?xt=urn:btih:\(normalized)&dn=\(title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? title)"
    }

    private static func firstMagnetHash(_ html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"magnet:\?xt=urn:btih:([a-fA-F0-9]{40})"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let r = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[r]).lowercased()
    }

    private static func firstSize(_ html: String) -> Int64? {
        guard let regex = try? NSRegularExpression(pattern: #"Size:\s*([\d.]+\s*[KMGT]?i?B)"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let r = Range(match.range(at: 1), in: html) else { return nil }
        return parseSize(String(html[r]))
    }

    static func parseSize(_ text: String) -> Int64? {
        guard let regex = try? NSRegularExpression(pattern: #"([\d.]+)\s*(Ti?B|Gi?B|Mi?B|Ki?B|B)"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let value = Double(text[numberRange]) else { return nil }
        let unit = text[unitRange].uppercased().replacingOccurrences(of: "I", with: "")
        let factor: Double
        switch unit {
        case "TB": factor = pow(1024, 4)
        case "GB": factor = pow(1024, 3)
        case "MB": factor = 1_048_576
        case "KB": factor = 1024
        default: factor = 1
        }
        let bytes = value * factor
        guard bytes >= 0, bytes < Double(Int64.max) else { return nil }
        return Int64(bytes)
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    private static func safeCover(_ value: Any?) -> String? {
        guard let string = value as? String, let url = URL(string: string),
              url.scheme == "https", url.host != "127.0.0.1", url.host != "localhost" else { return nil }
        return string
    }

    private static func isoDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func rssDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.date(from: value)
    }
}

// MARK: - RSS

final class RSSParser: NSObject, XMLParserDelegate {
    private(set) var items: [[String: String]] = []
    private var current: [String: String] = [:]
    private var text = ""
    private var inItem = false

    static func parse(_ data: Data) throws -> [[String: String]] {
        let parser = RSSParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else { throw SourceError.parse }
        return parser.items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "item" {
            inItem = true
            current = [:]
        } else if inItem, elementName == "enclosure", let url = attributeDict["url"] {
            current["enclosure"] = url
        } else if inItem, elementName == "link", let href = attributeDict["href"] {
            current["linkHref"] = href
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if elementName == "item" {
            items.append(current)
            inItem = false
        } else if inItem {
            let key = elementName.split(separator: ":").last.map(String.init) ?? elementName
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { current[key] = value }
        }
        text = ""
    }
}
