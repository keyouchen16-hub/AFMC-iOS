import Foundation

/// The Pirate Bay 公开 JSON 接口（与 Windows 端 PirateBaySource 对应）。
enum PirateBaySource {
    private struct Item: Decodable {
        let id: String
        let name: String
        let info_hash: String
        let leechers: String
        let seeders: String
        let size: String
        let added: String
        let status: String
        let category: String
    }

    static func search(query: String) async throws -> [SearchResult] {
        var components = URLComponents(string: "https://apibay.org/q.php")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { throw SourceError.badEndpoint }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SourceError.http(http.statusCode)
        }

        let items = try JSONDecoder().decode([Item].self, from: data)
        // 无结果时接口返回一条 id=0 的占位记录。
        guard items.first?.id != "0" else { return [] }

        return items.compactMap { item in
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, item.status != "vip" else { return nil }
            let hash = item.info_hash.lowercased()
            guard hash.count == 40 else { return nil }

            let dn = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
            return SearchResult(
                title: name,
                source: "The Pirate Bay",
                magnet: "magnet:?xt=urn:btih:\(hash)&dn=\(dn)",
                torrentURL: nil,
                detailsURL: "https://thepiratebay.org/description.php?id=\(item.id)",
                coverURL: nil,
                archiveId: nil,
                hash: hash,
                size: Int64(item.size),
                seeders: Int(item.seeders),
                category: categoryName(item.category),
                published: TimeInterval(item.added).map { Date(timeIntervalSince1970: $0) }
            )
        }
    }

    private static func categoryName(_ raw: String) -> String {
        guard let code = Int(raw) else { return "未知" }
        switch code / 100 {
        case 1: return "音频"
        case 2: return "视频"
        case 3: return "应用"
        case 4: return "游戏"
        case 5: return "其他"
        case 6: return "其他"
        default: return "未知"
        }
    }
}
