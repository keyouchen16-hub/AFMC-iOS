import Foundation

/// 轻量 HTML 扫描工具（对应 Windows 端 HtmlAgilityPack 的定点查询）。
enum HTML {
    static func matches(_ pattern: String, in text: String, groups: Int? = nil) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0...(groups ?? (match.numberOfRanges - 1))).map { index in
                guard index < match.numberOfRanges, match.range(at: index).location != NSNotFound else { return "" }
                return ns.substring(with: match.range(at: index))
            }
        }
    }

    static func first(_ pattern: String, in text: String, groups: Int? = nil) -> [String]? {
        matches(pattern, in: text, groups: groups).first
    }

    static func strip(_ value: String) -> String {
        var text = value
        text = text.replacingOccurrences(of: "<script[^>]*>.*?</script>", with: " ",
                                        options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = decode(text)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decode(_ value: String) -> String {
        var text = value
        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
            "&apos;": "'", "&nbsp;": " ",
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        if let regex = try? NSRegularExpression(pattern: "&#(\\d+);") {
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                guard let scalar = UInt32(ns.substring(with: match.range(at: 1))) else { continue }
                let replacement = String(UnicodeScalar(scalar) ?? " ")
                text = (text as NSString).replacingCharacters(in: match.range, with: replacement)
            }
        }
        return text
    }
}
