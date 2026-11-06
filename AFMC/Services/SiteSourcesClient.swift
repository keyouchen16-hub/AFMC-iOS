import Foundation

/// Windows 端 HTML / 站点型来源的 Swift 移植（LinuxTracker、Lime、种子楼、TPB、磁力熊、EZTV）。
enum SiteSourcesClient {
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    // MARK: - HTTP

    static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8",
                         forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://\(url.host ?? "")/", forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SourceError.http(http.statusCode)
        }
        return data
    }

    static func postForm(_ url: URL, form: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SourceError.http(http.statusCode)
        }
        return data
    }

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    private static func magnet(_ hash: String, _ title: String) -> String {
        "magnet:?xt=urn:btih:\(hash)&dn=\(escape(title))"
    }

    // MARK: - Debian（官方目录）

    static func debian(_ query: String) async throws -> [SearchResult] {
        let directories = ["amd64/bt-cd/", "amd64/bt-dvd/", "arm64/bt-cd/", "arm64/bt-dvd/"]
        var collected: [SearchResult] = []
        for directory in directories {
            guard let base = URL(string: "https://cdimage.debian.org/debian-cd/current/\(directory)") else { continue }
            guard let data = try? await get(base), let html = String(data: data, encoding: .utf8) else { continue }
            for match in HTML.matches(#"<a href="(debian-[A-Za-z0-9.+_-]+\.iso\.torrent)""#, in: html) {
                let name = match[1]
                collected.append(SearchResult(
                    title: String(name.dropLast(8)),
                    source: "Debian 官方",
                    magnet: nil,
                    torrentURL: base.absoluteString + name,
                    detailsURL: base.absoluteString,
                    coverURL: nil,
                    archiveId: nil,
                    hash: nil,
                    size: nil,
                    seeders: nil,
                    category: "软件",
                    published: nil
                ))
            }
        }
        guard !collected.isEmpty else { throw SourceError.parse }
        let terms = SearchQuality.canonical(query).split(separator: " ").map(String.init)
        return Array(collected.filter { row in
            terms.allSatisfy { SearchQuality.canonical(row.title).contains($0) }
        }.prefix(30))
    }

    // MARK: - LinuxTracker

    static func linuxTracker(_ query: String) async throws -> [SearchResult] {
        var components = URLComponents(string: "https://linuxtracker.org/torrents/")!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "page", value: "1")]
        guard let html = String(data: try await get(components.url!), encoding: .utf8) else {
            throw SourceError.parse
        }
        guard let table = HTML.first(#"<table[^>]*torrent-table[^>]*>(.*?)</table>"#, in: html)?.last else {
            throw SourceError.parse
        }
        var results: [SearchResult] = []
        for row in HTML.matches(#"<tr[^>]*>(.*?)</tr>"#, in: table) {
            let content = row[1]
            guard let link = HTML.first(#"<a[^>]*torrent-name[^>]*href="/torrents/([a-fA-F0-9]{40})/"[^>]*>(.*?)</a>"#,
                                        in: content, groups: 2) else { continue }
            let hash = link[1].lowercased()
            let title = HTML.strip(link[2])
            guard !title.isEmpty else { continue }
            let cells = HTML.matches(#"<td[^>]*>(.*?)</td>"#, in: content)
            let size = cells.count > 3 ? SearchSourceClient.parseSize(HTML.strip(cells[3][1])) : nil
            var seeders: Int?
            if cells.count > 4, let strong = HTML.first(#"<strong>([\d,]+)</strong>"#, in: cells[4][1]) {
                seeders = Int(strong[1].replacingOccurrences(of: ",", with: ""))
            }
            results.append(SearchResult(
                title: title, source: "LinuxTracker",
                magnet: magnet(hash, title), detailsURL: "https://linuxtracker.org/torrents/\(hash)/",
                hash: hash, size: size, seeders: seeders, category: "软件"
            ))
        }
        return Array(results.prefix(25))
    }

    // MARK: - LimeTorrents

    static func limeTorrents(_ query: String) async throws -> [SearchResult] {
        let url = URL(string: "https://www.limetorrents.fun/search/all/\(escape(query))/seeds/1/")!
        guard let html = String(data: try await get(url), encoding: .utf8) else { throw SourceError.parse }
        guard let table = HTML.first(#"<table[^>]*table2[^>]*>(.*?)</table>"#, in: html)?.last else {
            if html.contains("No results found") { return [] }
            throw SourceError.parse
        }
        var results: [SearchResult] = []
        for row in HTML.matches(#"<tr[^>]*>(.*?)</tr>"#, in: table) {
            let content = row[1]
            guard let nameBlock = HTML.first(#"<div[^>]*tt-name[^>]*>(.*?)</div>"#, in: content)?.last,
                  let link = HTML.first(#"<a[^>]*href="(/[^"]*-torrent-[^"]*)"[^>]*>(.*?)</a>"#,
                                        in: nameBlock, groups: 2) else { continue }
            let path = HTML.decode(link[1])
            guard path.hasPrefix("/"), path.contains("-torrent-") else { continue }
            let title = HTML.strip(link[2])
            guard !title.isEmpty else { continue }
            let hashes = HTML.matches(#"itorrents\.(?:net|org)/torrent/([a-fA-F0-9]{40})\.torrent"#, in: content)
            let unique = Set(hashes.map { $0[1].lowercased() })
            guard unique.count == 1, let hash = unique.first else { continue }
            let cells = HTML.matches(#"<td[^>]*>(.*?)</td>"#, in: content)
            var category = cells.count > 1 ? HTML.strip(cells[1][1]) : "未知"
            if let marker = category.range(of: " - in ", options: .caseInsensitive) {
                category = String(category[marker.upperBound...])
            }
            let size = cells.count > 2 ? SearchSourceClient.parseSize(HTML.strip(cells[2][1])) : nil
            let seeders = cells.count > 3 ? Int(HTML.strip(cells[3][1]).replacingOccurrences(of: ",", with: "")) : nil
            results.append(SearchResult(
                title: title, source: "LimeTorrents",
                magnet: magnet(hash, title), detailsURL: "https://www.limetorrents.fun\(path)",
                hash: hash, size: size, seeders: seeders, category: category.isEmpty ? "未知" : category
            ))
        }
        return Array(results.prefix(100))
    }

    // MARK: - 种子楼

    static func zhongzilou(_ query: String) async throws -> [SearchResult] {
        let url = URL(string: "https://m.zhongzilou.com/list/\(escape(query))/1")!
        guard let html = String(data: try await get(url), encoding: .utf8) else { throw SourceError.parse }
        let blocks = HTML.matches(#"<ul[^>]*list-group[^>]*>(.*?)</ul>"#, in: html)
        if blocks.isEmpty {
            if html.contains("没有找到") || html.contains("未找到") || html.contains("没有搜索到") { return [] }
            throw SourceError.parse
        }
        var results: [SearchResult] = []
        for block in blocks.prefix(100) {
            let content = block[1]
            guard let link = HTML.first(#"<a[^>]*href="/info-([a-fA-F0-9]{40})[^"]*"[^>]*>(.*?)</a>"#,
                                        in: content, groups: 2) else { continue }
            let hash = link[1].lowercased()
            let title = HTML.strip(link[2])
            guard !title.isEmpty else { continue }
            let size = HTML.first(#"<dd[^>]*text-size[^>]*>(.*?)</dd>"#, in: content).flatMap {
                SearchSourceClient.parseSize(HTML.strip($0[1]))
            }
            let category = HTML.first(#"<dd[^>]*text-type[^>]*>(.*?)</dd>"#, in: content).map { HTML.strip($0[1]) } ?? "未知"
            let time = HTML.first(#"<dd[^>]*text-time[^>]*>(.*?)</dd>"#, in: content).map { HTML.strip($0[1]) }
            results.append(SearchResult(
                title: title, source: "种子楼",
                magnet: magnet(hash, title),
                detailsURL: "https://m.zhongzilou.com/info-\(hash).html",
                hash: hash, size: size, seeders: nil,
                category: category, published: parseDay(time)
            ))
        }
        return results
    }

    // MARK: - TPB Proxy

    static func tpbProxy(_ query: String) async throws -> [SearchResult] {
        let url = URL(string: "https://thepiratebay.party/search/\(escape(query))/1/99/0")!
        guard let html = String(data: try await get(url), encoding: .utf8) else { throw SourceError.parse }
        guard let table = HTML.first(#"<table[^>]*id="searchResult"[^>]*>(.*?)</table>"#, in: html)?.last else {
            throw SourceError.parse
        }
        var results: [SearchResult] = []
        for row in HTML.matches(#"<tr[^>]*>(.*?)</tr>"#, in: table) {
            let content = row[1]
            guard let link = HTML.first(#"<a[^>]*href="/torrent/(\d+)[^"]*"[^>]*>(.*?)</a>"#, in: content, groups: 2),
                  let magnetValue = HTML.first(#"href="(magnet:[^"]+)""#, in: content)?.last,
                  let hash = Links.magnetHash(HTML.decode(magnetValue)) else { continue }
            let title = HTML.strip(link[2])
            guard !title.isEmpty else { continue }
            let cells = HTML.matches(#"<td[^>]*>(.*?)</td>"#, in: content)
            let category = cells.count > 0 ? HTML.strip(cells[0][1]) : "未知"
            let size = cells.count > 4 ? SearchSourceClient.parseSize(HTML.strip(cells[4][1])) : nil
            let seeders = cells.count > 5 ? Int(HTML.strip(cells[5][1])) : nil
            results.append(SearchResult(
                title: title, source: "TPB Proxy",
                magnet: magnet(hash, title),
                detailsURL: "https://thepiratebay.party/torrent/\(link[1])",
                hash: hash, size: size, seeders: seeders, category: category
            ))
        }
        return results
    }

    // MARK: - 磁力熊

    static func cilixiong(_ query: String) async throws -> [SearchResult] {
        let searchURL = URL(string: "https://www.cilixiong.cc/e/search/index.php")!
        let data = try await postForm(searchURL, form: [
            "classid": "1,2", "show": "title", "tempid": "1", "keyboard": query,
        ])
        guard let html = String(data: data, encoding: .utf8) else { throw SourceError.parse }
        if html.contains("系统限制的搜索时间间隔") { throw SourceError.api("磁力熊要求搜索间隔至少 5 秒") }
        let links = HTML.matches(#"href="(/(movie|drama)/\d+\.html)""#, in: html)
        let unique = Array(Set(links.map { $0[1] })).prefix(8)
        if unique.isEmpty {
            if html.contains("没有找到") || html.contains("找到 0") || html.contains("没有查询到") { return [] }
            throw SourceError.parse
        }
        var results: [SearchResult] = []
        for path in unique {
            guard let url = URL(string: "https://www.cilixiong.cc\(path)"),
                  let detail = try? await get(url),
                  let page = String(data: detail, encoding: .utf8) else { continue }
            guard let title = HTML.first(#"<h1[^>]*>(.*?)</h1>"#, in: page).map({ HTML.strip($0[1]) }),
                  !title.isEmpty else { continue }
            var poster: String?
            if let image = HTML.first(#"<img[^>]*rounded-2[^>]*src="([^"]+)""#, in: page)?.last
                ?? HTML.first(#"<img[^>]*src="([^"]+)"[^>]*rounded-2"#, in: page)?.last,
               image.hasPrefix("https://i.nacloud.cc/") {
                poster = image
            }
            let category = path.hasPrefix("/drama/") ? "剧集" : "电影"
            for anchor in HTML.matches(#"<a[^>]*href="(magnet:[^"]+)"[^>]*>(.*?)</a>"#, in: page) {
                let magnetValue = HTML.decode(anchor[1])
                guard let hash = Links.magnetHash(magnetValue) else { continue }
                let release = HTML.strip(anchor[2])
                let combined = title + (release.isEmpty ? "" : " · " + release)
                let size = HTML.first(#"\[(\d+(?:\.\d+)?)\s*([GMT])(?:i?B)?\]"#, in: release).flatMap {
                    SearchSourceClient.parseSize($0[1] + $0[2] + "B")
                }
                results.append(SearchResult(
                    title: String(combined.prefix(1000)), source: "磁力熊",
                    magnet: magnetValue, detailsURL: url.absoluteString,
                    coverURL: poster, hash: hash, size: size, seeders: nil, category: category
                ))
            }
        }
        if results.isEmpty { throw SourceError.parse }
        return results
    }

    // MARK: - EZTV

    static func eztv(_ query: String) async throws -> [SearchResult] {
        let name = mediaName(query)
        guard name.count >= 2 else { return [] }
        let searchURL = URL(string: "https://api.tvmaze.com/search/shows?q=\(escape(name))")!
        let data = try await get(searchURL)
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw SourceError.parse
        }
        var ids: [String] = []
        for entry in rows.prefix(20) {
            guard let show = entry["show"] as? [String: Any],
                  let showName = show["name"] as? String,
                  SearchQuality.canonical(showName) == name else { continue }
            if let externals = show["externals"] as? [String: Any],
               let imdb = externals["imdb"] as? String,
               imdb.range(of: #"^tt\d{7,10}$"#, options: .regularExpression) != nil {
                ids.append(String(imdb.dropFirst(2)))
            }
        }
        ids = Array(Set(ids)).prefix(2).map { $0 }

        var results: [SearchResult] = []
        var seen = Set<String>()
        for id in ids {
            for page in 1...3 {
                let url = URL(string: "https://eztvx.to/api/get-torrents?imdb_id=\(id)&limit=100&page=\(page)")!
                guard let pageData = try? await get(url),
                      let root = try? JSONSerialization.jsonObject(with: pageData) as? [String: Any] else { break }
                let torrents = root["torrents"] as? [[String: Any]] ?? []
                for row in torrents.prefix(100) {
                    guard let title = row["title"] as? String, !title.isEmpty,
                          let hash = Links.normalizeHash(row["hash"] as? String),
                          let magnetValue = row["magnet_url"] as? String,
                          Links.magnetHash(magnetValue) == hash,
                          (" " + SearchQuality.canonical(title) + " ").contains(" " + name + " "),
                          SearchQuality.matchesConstraints(query, title),
                          seen.insert(hash).inserted else { continue }
                    let size = row["size_bytes"].flatMap { value -> Int64? in
                        if let number = value as? NSNumber { return number.int64Value }
                        if let string = value as? String { return Int64(string) }
                        return nil
                    }
                    var published: Date?
                    if let epoch = row["date_released_unix"] as? NSNumber {
                        published = Date(timeIntervalSince1970: epoch.doubleValue)
                    }
                    results.append(SearchResult(
                        title: title, source: "EZTV",
                        magnet: magnetValue,
                        detailsURL: "https://eztvx.to/api/get-torrents?imdb_id=\(id)",
                        hash: hash, size: size,
                        seeders: (row["seeds"] as? NSNumber)?.intValue,
                        category: "影视", published: published
                    ))
                }
                if torrents.count < 100 { break }
            }
        }
        return results
    }

    static func mediaName(_ query: String) -> String {
        var name = SearchQuality.canonical(query)
        let remove = [#"\b(?:s\d{2,3}|e\d{2,3}|\d{3,4}p|(?:19|20)\d{2}|hevc|bluray|x264|x265)\b"#]
        for pattern in remove {
            name = name.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        return name.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func parseDay(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}
