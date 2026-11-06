import Foundation

struct DiscoveryCandidate: Identifiable {
    let id = UUID()
    let template: String
    let note: String
}

/// 网页搜索入口发现（Windows `WebsiteDiscovery` 的静态 HTML 版）。
enum WebsiteDiscovery {
    private static let preferredNames = ["q", "query", "keyword", "keywords", "search", "s", "wd", "term", "search_query"]

    static func discover(_ input: String, useBrowser: Bool = false) async throws -> [DiscoveryCandidate] {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme,
              scheme == "https" || scheme == "http" else {
            throw SourceError.badEndpoint
        }
        if useBrowser {
            let html = try await BrowserPageLoader.shared.loadHTML(url)
            return parse(html: html, baseURL: url)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SourceError.http(http.statusCode)
        }
        let staticCandidates = parse(html: String(decoding: data, as: UTF8.self), baseURL: url)
        if !staticCandidates.isEmpty { return staticCandidates }
        // 静态页面没有搜索入口时，用浏览器渲染后再试一次。
        if let html = try? await BrowserPageLoader.shared.loadHTML(url) {
            return parse(html: html, baseURL: url)
        }
        return []
    }

    static func parse(html: String, baseURL: URL) -> [DiscoveryCandidate] {
        var candidates: [DiscoveryCandidate] = []
        var seen = Set<String>()

        for form in HTML.matches(#"<form[^>]*action="([^"]*)"[^>]*>(.*?)</form>"#, in: html, groups: 2) {
            let action = HTML.decode(form[1])
            let body = form[2]
            let inputs = HTML.matches(#"<input[^>]*>"#, in: body)
            guard let parameter = queryParameter(in: inputs) else { continue }
            let resolved = resolve(action.isEmpty ? baseURL.absoluteString : action, base: baseURL)
            guard let template = templateURL(resolved, parameter: parameter) else { continue }
            if seen.insert(template).inserted {
                candidates.append(DiscoveryCandidate(template: template, note: "表单搜索 · \(baseURL.host ?? "")"))
            }
        }

        for link in HTML.matches(#"<a[^>]*href="([^"]*(?:[?&])(?:q|query|keyword|search|wd|s)=[^"]*)"[^>]*>"#, in: html, groups: 1) {
            let href = HTML.decode(link[1])
            guard let resolved = resolve(href, base: baseURL),
                  let template = replaceQueryValue(resolved) else { continue }
            if seen.insert(template).inserted {
                candidates.append(DiscoveryCandidate(template: template, note: "页面搜索链接 · \(baseURL.host ?? "")"))
            }
        }

        return Array(candidates.prefix(5))
    }

    /// 用固定关键词验证模板确实能返回内容。
    static func validate(_ template: String) async -> Bool {
        let value = template.replacingOccurrences(of: "{q}", with: "test")
            .replacingOccurrences(of: "{query}", with: "test")
        guard let url = URL(string: value) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return false
        }
        return data.count > 500
    }

    // MARK: - 解析辅助

    private static func queryParameter(in inputs: [[String]]) -> String? {
        var textInput: String?
        for input in inputs {
            let tag = input[0]
            guard let name = attribute("name", in: tag), !name.isEmpty,
                  let type = attribute("type", in: tag)?.lowercased() else { continue }
            if type == "hidden" { continue }
            if preferredNames.contains(name.lowercased()) { return name }
            if textInput == nil && (type == "search" || type == "text") {
                textInput = name
            }
        }
        return textInput
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\b"# + name + #"\s*=\s*"([^"]*)""#
        return HTML.first(pattern, in: tag)?.last.map { HTML.decode($0) }
    }

    private static func resolve(_ value: String, base: URL) -> URL? {
        guard !value.isEmpty, !value.hasPrefix("javascript:") else { return nil }
        return URL(string: value, relativeTo: base)?.absoluteURL
    }

    private static func templateURL(_ url: URL?, parameter: String) -> String? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == parameter }
        items.append(URLQueryItem(name: parameter, value: "AFMCQ"))
        components.queryItems = items
        return components.url?.absoluteString.replacingOccurrences(of: "AFMCQ", with: "{q}")
    }

    private static func replaceQueryValue(_ url: URL?) -> String? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return nil }
        var replaced = false
        let updated = items.map { item -> URLQueryItem in
            if !replaced, preferredNames.contains(item.name.lowercased()) || item.name.lowercased() == "s" {
                replaced = true
                return URLQueryItem(name: item.name, value: "AFMCQ")
            }
            return item
        }
        guard replaced else { return nil }
        components.queryItems = updated
        return components.url?.absoluteString.replacingOccurrences(of: "AFMCQ", with: "{q}")
    }
}
