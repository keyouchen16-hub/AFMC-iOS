import Foundation

enum SourceKind: String, Codable, CaseIterable, Identifiable {
    case piratebay
    case torznab
    case archive
    case knaben
    case bitsearch
    case nyaa
    case dmhy
    case torrentscsv
    case tokyotosho
    case foss
    case debian
    case linuxtracker
    case limetorrents
    case zhongzilou
    case tpbproxy
    case cilixiong
    case eztv
    case website

    var id: String { rawValue }

    var label: String {
        switch self {
        case .piratebay: return "海盗湾"
        case .torznab: return "Torznab / Jackett"
        case .archive: return "Internet Archive"
        case .knaben: return "Knaben"
        case .bitsearch: return "BitSearch"
        case .nyaa: return "Nyaa"
        case .dmhy: return "动漫花园"
        case .torrentscsv: return "Torrents.csv"
        case .tokyotosho: return "Tokyo Toshokan"
        case .foss: return "FOSS Torrents"
        case .debian: return "Debian 官方"
        case .linuxtracker: return "LinuxTracker"
        case .limetorrents: return "LimeTorrents"
        case .zhongzilou: return "种子楼"
        case .tpbproxy: return "TPB Proxy"
        case .cilixiong: return "磁力熊"
        case .eztv: return "EZTV"
        case .website: return "网页磁力源"
        }
    }
}

struct SourceConfig: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var kind: SourceKind
    var endpoint: String
    var apiKey: String
    var enabled: Bool
    var note: String
    var useBrowser: Bool

    init(id: String = UUID().uuidString, name: String = "新搜索源", kind: SourceKind = .torznab,
         endpoint: String = "", apiKey: String = "", enabled: Bool = true, note: String = "",
         useBrowser: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.enabled = enabled
        self.note = note
        self.useBrowser = useBrowser
    }

    enum CodingKeys: String, CodingKey { case id, name, kind, endpoint, apiKey, enabled, note, useBrowser }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "搜索源"
        kind = try container.decodeIfPresent(SourceKind.self, forKey: .kind) ?? .torznab
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        useBrowser = try container.decodeIfPresent(Bool.self, forKey: .useBrowser) ?? false
    }
}

struct SearchResult: Identifiable, Hashable {
    var id: String = UUID().uuidString
    var title: String
    var source: String
    var magnet: String?
    var torrentURL: String?
    var detailsURL: String?
    var coverURL: String?
    var archiveId: String?
    var hash: String?
    var size: Int64?
    var seeders: Int?
    var category: String = "未知"
    var published: Date?
    var releaseYear: Int?

    var contentYear: Int? {
        if let releaseYear, (1888...Calendar.current.component(.year, from: Date()) + 1).contains(releaseYear) {
            return releaseYear
        }
        guard let regex = try? NSRegularExpression(pattern: #"(?<![a-zA-Z\d])(?:19|20)\d{2}(?![a-zA-Z\d])"#) else { return nil }
        let clean = SearchQuality.displayTitle(title)
        let years = Set(regex.matches(in: clean, range: NSRange(clean.startIndex..., in: clean)).compactMap { match -> Int? in
            guard let range = Range(match.range, in: clean), let year = Int(clean[range]),
                  year <= Calendar.current.component(.year, from: Date()) + 1 else { return nil }
            return year
        })
        return years.count == 1 ? years.first : nil
    }

    var uploadDate: Date? {
        guard let published, published.timeIntervalSince1970 > 0,
              published <= Date().addingTimeInterval(86400) else { return nil }
        return published
    }

    var sizeText: String {
        guard let size else { return "未知" }
        let gb = Double(size) / 1_073_741_824
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        let mb = Double(size) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return "\(size) B"
    }

    var seedsText: String { seeders.map(String.init) ?? "未知" }

    var publishedText: String {
        guard let published else { return "未知" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: published)
    }

    var playableDirectURL: URL? {
        guard let torrentURL, let url = URL(string: torrentURL) else { return nil }
        let ext = url.pathExtension.lowercased()
        if ["mp4", "m4v", "mov", "m3u8", "webm"].contains(ext) { return url }
        return nil
    }
}

enum SortOption: String, CaseIterable, Identifiable {
    case relevance
    case verified
    case seeders
    case newest
    case year
    case size
    case title

    var id: String { rawValue }

    var label: String {
        switch self {
        case .relevance: return "推荐"
        case .verified: return "已验证优先"
        case .seeders: return "做种优先"
        case .newest: return "最近上传"
        case .year: return "最新年份"
        case .size: return "文件大小"
        case .title: return "名称"
        }
    }

    func detail(for row: SearchResult) -> String? {
        switch self {
        case .year: return row.contentYear.map { "标注年份 · \($0)" } ?? "作品年份未知"
        case .newest: return row.uploadDate.map { "来源上传 · " + $0.formatted(date: .numeric, time: .omitted) } ?? "上传时间未知"
        default: return nil
        }
    }
}

struct ResourceGroup: Identifiable {
    let id: String
    let title: String
    let results: [SearchResult]

    var isGrouped: Bool { results.count > 1 }
}

struct SourceReport: Identifiable {
    let id = UUID()
    var name: String
    var count: Int
    var error: String?
    var seconds: Double

    var statusText: String {
        if let error { return count > 0 ? "部分成功 · \(count) 条 · \(error)" : "失败 · \(error)" }
        return count > 0 ? "成功 · \(count) 条" : "无结果"
    }
}
