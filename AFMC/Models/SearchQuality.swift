import Foundation

/// Windows 端 `SearchQuality` 的 Swift 移植：规范化、约束、匹配层级、相关度、分类与规格。
enum SearchQuality {
    // MARK: - 基础

    private static func replace(_ text: String, _ pattern: String, _ template: String,
                                caseInsensitive: Bool = true) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: caseInsensitive ? [.caseInsensitive] : []) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func replaceMatches(_ text: String, _ pattern: String, caseInsensitive: Bool = true,
                                       transform: (NSTextCheckingResult, String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: caseInsensitive ? [.caseInsensitive] : []) else {
            return text
        }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(match, result))
        }
        return result
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        guard index < match.numberOfRanges,
              let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }

    private static func chineseNumber(_ value: String) -> Int? {
        if let n = Int(value) { return n }
        let digits = "零一二三四五六七八九"
        if value == "十" { return 10 }
        if value.contains("十") {
            let parts = value.components(separatedBy: "十")
            let tens = parts[0].isEmpty ? 1 : (digits.firstIndex(of: parts[0].first!).map { digits.distance(from: digits.startIndex, to: $0) } ?? -1)
            let ones = parts.count > 1 && !parts[1].isEmpty ? (digits.firstIndex(of: parts[1].first!).map { digits.distance(from: digits.startIndex, to: $0) } ?? -1) : 0
            guard tens >= 0, ones >= 0 else { return nil }
            return tens * 10 + ones
        }
        guard value.count == 1, let index = digits.firstIndex(of: value.first!) else { return nil }
        return digits.distance(from: digits.startIndex, to: index)
    }

    // MARK: - 规范化

    static func canonical(_ text: String) -> String {
        var s = text.precomposedStringWithCompatibilityMapping.lowercased()
        s = replace(s, #"(?<=[\u3400-\u9fff])((?:19|20)\d{2})(?!\d)"#, " $1 ")
        s = s.replacingOccurrences(of: "中文字幕", with: "中字")
        s = replaceMatches(s, #"第([0-9一二三四五六七八九十]+)(季|集)"#, caseInsensitive: false) { match, source in
            guard let numberText = group(match, 1, in: source),
                  let number = chineseNumber(numberText),
                  let unit = group(match, 2, in: source) else { return group(match, 0, in: source) ?? "" }
            return " " + (unit == "季" ? "s" : "e") + String(format: "%02d", number) + " "
        }
        s = replaceMatches(s, #"\bseason[ ._-]*(\d{1,2})\b"#) { match, source in
            guard let number = group(match, 1, in: source).flatMap(Int.init) else { return group(match, 0, in: source) ?? "" }
            return " s" + String(format: "%02d", number) + " "
        }
        s = replace(s, #"\b(s\d{1,2})(e\d{1,3})\b"#, "$1 $2")
        s = replaceMatches(s, #"\b([se])(\d{1,3})\b"#, caseInsensitive: false) { match, source in
            guard let letter = group(match, 1, in: source),
                  let number = group(match, 2, in: source).flatMap(Int.init) else { return group(match, 0, in: source) ?? "" }
            return letter + String(format: "%02d", number)
        }
        s = replace(s, #"\b4k\b"#, "2160p")
        s = replace(s, #"\b8k\b"#, "4320p")
        s = replace(s, #"(?<!\w)v(?=\d+\.)"#, "")
        s = replace(s, #"[^\p{L}\p{N}]+"#, " ", caseInsensitive: false)
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func contains(_ title: String, _ token: String) -> Bool {
        let hasCJK = token.range(of: #"[\u3400-\u9fff]"#, options: .regularExpression) != nil
        if hasCJK { return title.contains(token) }
        return (" " + title + " ").contains(" " + token + " ")
    }

    // MARK: - 约束

    static func constraints(_ query: String) -> [String] {
        let canonicalQuery = canonical(query)
        var output: [String] = []
        if let regex = try? NSRegularExpression(pattern: #"\b(?:(?:19|20)\d{2}|\d{3,4}p|s\d{2,3}|e\d{2,3})\b"#,
                                                options: [.caseInsensitive]) {
            let range = NSRange(canonicalQuery.startIndex..., in: canonicalQuery)
            for match in regex.matches(in: canonicalQuery, range: range) {
                if let r = Range(match.range, in: canonicalQuery) { output.append(String(canonicalQuery[r])) }
            }
        }
        if let regex = try? NSRegularExpression(pattern: #"(?<!\d)\d{1,4}(?:\.\d{1,4})+(?!\d)"#) {
            let range = NSRange(query.startIndex..., in: query)
            for match in regex.matches(in: query, range: range) {
                if let r = Range(match.range, in: query) { output.append(canonical(String(query[r]))) }
            }
        }
        for tag in ["国语", "粤语", "中字", "双语"] where canonicalQuery.contains(tag) {
            output.append(tag)
        }
        return output
    }

    static func matchesConstraints(_ query: String, _ title: String) -> Bool {
        let canonicalTitle = canonical(title)
        return constraints(query).allSatisfy { contains(canonicalTitle, $0) }
    }

    // MARK: - 匹配层级与评分

    static func matchTier(_ query: String, _ title: String) -> Int {
        let q = canonical(query)
        guard !q.isEmpty else { return 0 }
        let constraintList = constraints(query)
        var name = " " + q + " "
        for constraint in constraintList {
            name = name.replacingOccurrences(of: " " + constraint + " ", with: " ")
        }
        let tokens = Array(Set(name.split(separator: " ").map(String.init)))
        let t = canonical(title)
        if tokens.isEmpty {
            return constraintList.allSatisfy { contains(t, $0) } ? 0 : 3
        }
        let matched = tokens.filter { contains(t, $0) }.count
        if matched == 0 { return 3 }
        if matched < tokens.count { return 2 }
        return constraintList.allSatisfy { contains(t, $0) } ? 0 : 1
    }

    private static func nameOrderScore(_ query: String, _ title: String) -> Double {
        var name = " " + canonical(query) + " "
        for constraint in constraints(query) {
            name = name.replacingOccurrences(of: " " + constraint + " ", with: " ")
        }
        name = replace(name, #"\b(?:epub|pdf|mobi|flac|mp3|aac|bluray|hevc|x264|x265)\b"#, "")
        let tokens = name.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return 0 }

        var clean = replace(title, #"^(?:(?:\[[^\]]{1,100}\]|【[^】]{1,100}】)\s*)+"#, "", caseInsensitive: false)
        clean = replace(clean, #"^(?:https?://)?www\.[^\s]+\s*-\s*"#, "")
        let words = canonical(clean).split(separator: " ").map(String.init)

        var position = -1
        var first = -1
        for token in tokens {
            guard position + 1 < words.count else { return tokens.count > 1 ? -12 : 0 }
            guard let found = words.indices.first(where: { $0 > position && words[$0] == token }) else {
                return tokens.count > 1 ? -12 : 0
            }
            if first < 0 { first = found }
            position = found
        }

        var seriesBonus = 0.0
        let canonicalQuery = canonical(query)
        if canonicalQuery.range(of: #"\bs\d{2,3}\b"#, options: .regularExpression) != nil {
            let boundary = words.firstIndex { $0.range(of: #"^(?:(?:19|20)\d{2}|s\d{2,3})$"#, options: .regularExpression) != nil } ?? -1
            if boundary > 0 && Array(words.prefix(boundary)) == tokens { seriesBonus = 24 }
        }
        let base = 12.0
        let positionBonus: Double = first == 0 ? 30 : (first <= 2 ? 12 : 0)
        return base + positionBonus + seriesBonus
    }

    static func score(_ query: String, _ row: SearchResult, now: Date = Date()) -> Double {
        let q = canonical(query)
        let title = canonical(row.title)
        let tokens = Array(Set(q.split(separator: " ").map(String.init)))
        guard !tokens.isEmpty else { return 0 }

        let coverage = Double(tokens.filter { contains(title, $0) }.count) / Double(tokens.count)
        var score = 70 * coverage * coverage + (q == title ? 5 : 0)
        score += nameOrderScore(query, row.title)
        if category(row) != "其他" { score += 8 }
        if !technicalSummary(row).isEmpty { score += 8 }
        if q == title && category(row) == "其他" && technicalSummary(row).isEmpty { score -= 10 }

        let extras = #"\b(?:addons?|plugins?|tutorials?|courses?|overview|fundamentals|guide|bible|essentials)\b|教程|课程|插件|指南|入门"#
        let softwareQuery = category(SearchResult(title: query, source: "query")) == "软件"
        if (softwareQuery || query.range(of: #"\d+\.\d+"#, options: .regularExpression) != nil)
            && query.range(of: extras, options: [.regularExpression, .caseInsensitive]) == nil {
            if row.title.range(of: extras, options: [.regularExpression, .caseInsensitive]) != nil { score -= 30 }
            if softwareQuery && (category(row) == "书籍" || category(row) == "影视"
                                 || row.title.range(of: #"\.(?:mp4|mkv|avi|webm)\b"#, options: [.regularExpression, .caseInsensitive]) != nil) {
                score -= 35
            }
        }

        if row.category.range(of: #"成人|\b(?:xxx|porn|adult)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
            && query.range(of: #"成人|色情|\b(?:xxx|porn|adult|hentai)\b"#, options: [.regularExpression, .caseInsensitive]) == nil {
            score -= 80
        }

        score += min(20, log10(1 + Double(max(0, row.seeders ?? 0))) * 5)
        if let published = row.published, published <= now {
            score += 5 / (1 + now.timeIntervalSince(published) / 86_400 / 365)
        }
        score -= Double(constraints(query).filter { !contains(title, $0) }.count) * 100
        return score
    }

    /// A preference within the same relevance and recent playback tier, never proof of availability.
    static func chinesePreference(_ query: String, _ row: SearchResult) -> Int {
        if query.range(of: #"英语|英文|日语|日文|韩语|韩文|原声|\b(?:english|japanese|korean)\b"#,
                       options: [.regularExpression, .caseInsensitive]) != nil { return 0 }
        let title = row.title
        var value = 0
        if title.range(of: #"国语|国英|国粤|普通话|国配|中文配音|\bmandarin\b"#,
                       options: [.regularExpression, .caseInsensitive]) != nil { value += 2 }
        if title.range(of: #"中文字幕|中字|简中|繁中|中英字幕|中英双字|\b(?:chs|cht)\b"#,
                       options: [.regularExpression, .caseInsensitive]) != nil { value += 2 }
        if title.range(of: #"[\u3400-\u9fff]"#, options: .regularExpression) != nil { value += 1 }
        if ["磁力熊", "种子楼", "动漫花园"].contains(row.source) { value += 1 }
        return value
    }

    // MARK: - 分类与规格

    static func category(_ row: SearchResult) -> String {
        let text = (row.category + " " + row.title).lowercased()
        if text.range(of: #"dataset|科研|数据集|academic"#, options: .regularExpression) != nil { return "科研" }
        if text.range(of: #"e[- ]?books?|audio.?book|书|\.epub\b|\.pdf\b"#, options: .regularExpression) != nil { return "书籍" }
        if text.range(of: #"anime|动漫|动画"#, options: .regularExpression) != nil { return "动漫" }
        if row.category.lowercased().range(of: #"\b(?:movies?|film|video|tv)\b|电影|影视|剧|视频"#, options: .regularExpression) != nil
            || row.title.range(of: #"\.(?:mkv|mp4|m4v|avi|mov|webm|m2ts)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return "影视"
        }
        let stripped = replace(text, #"\b(?:dual|multi(?:ple)?)\s*[- .]?\s*audio\b"#, "")
        if stripped.range(of: #"music|audio|音乐|\.flac\b|\.mp3\b"#, options: .regularExpression) != nil { return "音乐" }
        if stripped.range(of: #"software|application|软件|linux|ubuntu|\b(?:debian|blender|libreoffice|gimp)\b|\.iso\b"#, options: .regularExpression) != nil {
            return "软件"
        }
        if stripped.range(of: #"game|游戏|console"#, options: .regularExpression) != nil { return "游戏" }
        if stripped.range(of: #"movie|film|电影|剧|tv|video|视频|\b(?:1080p|2160p|720p|bluray|web.?dl|s\d{2})\b"#, options: .regularExpression) != nil {
            return "影视"
        }
        return "其他"
    }

    static func technicalSummary(_ row: SearchResult) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"\b(?:\d{3,4}p|[48]k|BluRay|WEB[- .]?DL|x26[45]|H[ .]?26[45]|HEVC|FLAC|MP3|EPUB|PDF|S\d{1,2}E\d{1,3})\b|国语|粤语|中字|双语"#,
            options: [.caseInsensitive]) else { return "" }
        let range = NSRange(row.title.startIndex..., in: row.title)
        var seen = Set<String>()
        var tags: [String] = []
        for match in regex.matches(in: row.title, range: range) {
            guard let r = Range(match.range, in: row.title) else { continue }
            let value = String(row.title[r])
            if seen.insert(value.lowercased()).inserted { tags.append(value) }
            if tags.count >= 6 { break }
        }
        return tags.joined(separator: " · ")
    }

    static func displayTitle(_ title: String) -> String {
        replace(title, #"^(?:\s*(?:【[^】]*(?:发布|www\.|\.com)[^】]*】|\[[^\]]*(?:发布|www\.|\.com|\.net)[^\]]*\]))+\s*"#, "")
    }

    static func workKeys(_ row: SearchResult) -> [String] {
        guard category(row) == "影视" || category(row) == "动漫" else { return [] }
        let title = displayTitle(row.title)
        let normalized = canonical(title)
        guard let yearRegex = try? NSRegularExpression(pattern: #"\b(?:19|20)\d{2}\b"#) else { return [] }
        let yearMatches = yearRegex.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized))
        guard yearMatches.count == 1,
              let rawRange = Range(yearMatches[0].range, in: normalized) else { return [] }
        let year = String(normalized[rawRange])

        var season = ""
        if let seasonRegex = try? NSRegularExpression(pattern: #"\bs\d{2,3}(?: e\d{2,3})?\b"#),
           let seasonMatch = seasonRegex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
           let seasonRange = Range(seasonMatch.range, in: normalized) {
            season = String(normalized[seasonRange])
        }
        if normalized.range(of: #"\be\d{2,3}\b"#, options: .regularExpression) != nil && season.isEmpty { return [] }

        // year 在原始标题中的位置
        guard let rawYear = title.range(of: #"(?<!\d)(?:19|20)\d{2}(?!\d)"#, options: .regularExpression) else { return [] }
        let prefix = String(title[..<rawYear.lowerBound])
        let parts = regexSplit(prefix, pattern: #"\s*[·|/]\s*|(?<=[\u3400-\u9fff])[\s._-]+(?=[A-Za-z])"#)
        return parts.map { canonical($0) }
            .map { replace($0, #"\b(?:s\d{2,3}|e\d{2,3}|director s cut|extended|remastered|unrated)\b"#, "").trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 2 && $0.count <= 100 }
            .map { "\(year):\(season):\($0)" }
            .uniqued()
    }

    static func explain(_ query: String, _ row: SearchResult) -> String {
        let q = canonical(query)
        let title = canonical(row.title)
        var match: String
        if !matchesConstraints(query, row.title) {
            match = "缺少指定年份 / 季集 / 版本"
        } else if q.isEmpty {
            match = "已收藏资源"
        } else if q.split(separator: " ").allSatisfy({ contains(title, String($0)) }) {
            match = constraints(query).isEmpty ? "关键词匹配 · 请核对类别与版本" : "关键词与指定条件匹配"
        } else {
            match = "部分名称匹配"
        }
        if matchTier(query, row.title) == 3 { match = "名称未匹配" }
        let seeds = row.seeders.map { $0 > 0 ? "来源报告有做种" : "来源报告零做种" } ?? "做种未知"
        return match + " · " + seeds
    }
}

private func regexSplit(_ text: String, pattern: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [text] }
    let ns = text as NSString
    var parts: [String] = []
    var last = 0
    for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        parts.append(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
        last = match.range.location + match.range.length
    }
    parts.append(ns.substring(from: last))
    return parts
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
