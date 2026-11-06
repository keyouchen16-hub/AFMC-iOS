import Foundation

/// Torznab / Jackett 兼容搜索。
enum TorznabSource {
    static func search(_ config: SourceConfig, query: String, session: URLSession = .shared) async throws -> [SearchResult] {
        guard var components = URLComponents(string: config.endpoint) else { throw SourceError.badEndpoint }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "t", value: "search"))
        items.append(URLQueryItem(name: "q", value: query))
        if !config.apiKey.isEmpty {
            items.append(URLQueryItem(name: "apikey", value: config.apiKey))
        }
        components.queryItems = items
        guard let url = components.url else { throw SourceError.badEndpoint }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SourceError.http(http.statusCode)
        }

        let parser = TorznabParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else { throw SourceError.parse }

        return parser.items.compactMap { item in
            let title = (item["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }

            let link = item["link"]
            let magnet = item["attr:magneturl"] ?? (link?.hasPrefix("magnet:") == true ? link : nil)
            let torrent = item["enclosure"] ?? (link?.hasPrefix("http") == true ? link : nil)
            let size = Int64(item["torznab:size"] ?? item["enclosureLength"] ?? "")
            let seeders = Int(item["attr:seeders"] ?? item["attr:peers"] ?? "")
            let details = item["guid"] ?? item["comments"]
            let category = item["attr:category"]?.trimmingCharacters(in: .whitespacesAndNewlines)

            return SearchResult(
                title: title,
                source: config.name,
                magnet: magnet,
                torrentURL: torrent,
                detailsURL: details,
                coverURL: nil,
                archiveId: nil,
                hash: Links.magnetHash(magnet) ?? Links.normalizeHash(item["torznab:infohash"]),
                size: size,
                seeders: seeders,
                category: (category?.isEmpty == false ? category! : "未知"),
                published: parseRFC822(item["pubDate"])
            )
        }
    }

    /// 连接测试：用固定关键词做一次查询，能解析即视为连通。
    static func test(_ config: SourceConfig, session: URLSession = .shared) async throws -> Int {
        try await search(config, query: "test", session: session).count
    }

    private static func parseRFC822(_ value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        if let date = formatter.date(from: value) { return date }
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter.date(from: value)
    }
}

private final class TorznabParser: NSObject, XMLParserDelegate {
    private(set) var items: [[String: String]] = []
    private var current: [String: String] = [:]
    private var text = ""
    private var inItem = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "item" {
            inItem = true
            current = [:]
        } else if inItem, elementName == "torznab:attr" {
            if let name = attributeDict["name"], let value = attributeDict["value"] {
                current["attr:" + name] = value
            }
        } else if inItem, elementName == "enclosure" {
            if let url = attributeDict["url"] { current["enclosure"] = url }
            if let length = attributeDict["length"] { current["enclosureLength"] = length }
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
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { current[elementName] = value }
        }
        text = ""
    }
}
