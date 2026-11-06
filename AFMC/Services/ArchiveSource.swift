import Foundation

/// Internet Archive 公开搜索与可播放文件解析。
enum ArchiveSource {
    private struct SearchResponse: Decodable {
        struct Inner: Decodable { let docs: [Doc] }
        struct Doc: Decodable {
            let identifier: String
            let title: String?
            let year: String?
            let mediatype: String?
        }
        let response: Inner
    }

    static func search(query: String) async throws -> [SearchResult] {
        var components = URLComponents(string: "https://archive.org/advancedsearch.php")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fl[]", value: "identifier"),
            URLQueryItem(name: "fl[]", value: "title"),
            URLQueryItem(name: "fl[]", value: "year"),
            URLQueryItem(name: "fl[]", value: "mediatype"),
            URLQueryItem(name: "rows", value: "40"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "output", value: "json"),
        ]
        guard let url = components.url else { throw SourceError.badEndpoint }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SourceError.http(http.statusCode)
        }

        do {
            let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
            return decoded.response.docs.map { doc in
                SearchResult(
                    title: doc.title ?? doc.identifier,
                    source: "Internet Archive",
                    magnet: nil,
                    torrentURL: nil,
                    detailsURL: "https://archive.org/details/\(doc.identifier)",
                    coverURL: "https://archive.org/services/img/\(doc.identifier)",
                    archiveId: doc.identifier,
                    hash: nil,
                    size: nil,
                    seeders: nil,
                    category: doc.mediatype ?? "未知",
                    published: nil,
                    releaseYear: doc.year.flatMap(Int.init)
                )
            }
        } catch {
            throw SourceError.parse
        }
    }

    /// 通过 metadata API 找第一个可播放的视频文件。
    static func playableURL(archiveId: String) async -> URL? {
        guard let url = URL(string: "https://archive.org/metadata/\(archiveId)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = root["files"] as? [[String: Any]] else { return nil }

        let candidates = files.filter { file in
            guard let name = file["name"] as? String else { return false }
            let lower = name.lowercased()
            let format = (file["format"] as? String ?? "").lowercased()
            return lower.hasSuffix(".mp4") || lower.hasSuffix(".m4v") || lower.hasSuffix(".webm")
                || lower.hasSuffix(".ogv") || format.contains("mpeg4") || format.contains("h.264")
        }
        guard let name = candidates.first?["name"] as? String else { return nil }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return URL(string: "https://archive.org/download/\(archiveId)/\(encoded)")
    }
}
