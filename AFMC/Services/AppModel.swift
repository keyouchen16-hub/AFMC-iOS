import Foundation

struct SourceOutcome {
    let report: SourceReport
    let results: [SearchResult]
}

@MainActor
final class AppModel: ObservableObject {
    @Published var query = ""
    @Published var results: [SearchResult] = [] {
        didSet { resultsRevision += 1 }
    }
    @Published var reports: [SourceReport] = []
    @Published var isSearching = false
    @Published var statusText = "输入关键词开始搜索"
    @Published var preferChineseResults = UserDefaults.standard.object(forKey: "afmc.preferChineseResults") as? Bool ?? true {
        didSet { UserDefaults.standard.set(preferChineseResults, forKey: "afmc.preferChineseResults") }
    }
    @Published var sortOption: SortOption = .relevance
    @Published var categoryFilter = "全部"
    private var resultsRevision = 0
    private var rankingQuery: String?
    private var featureQuery = ""
    private struct Features {
        let match: Int
        let score: Double
        let language: Int
        let category: String
        let workKey: String
        let year: Int?
    }
    private var features: [SearchResult: Features] = [:]
    private struct PresentationKey: Equatable {
        let revision: Int
        let query: String
        let sort: SortOption
        let category: String
        let chinese: Bool
        let evidence: Int
    }
    private var presentationKey: PresentationKey?
    private var presentationTime = Date.distantPast
    private var cachedRows: [SearchResult] = []
    private var cachedGroups: [ResourceGroup] = []
    private var cachedCategories: [String] = []
    private var cachedSortNotice: String?

    var sortNotice: String? { refreshPresentation(); return cachedSortNotice }

    private nonisolated static func prepare(_ rows: [SearchResult], query: String,
                                           existing: [SearchResult: Features]) -> [SearchResult: Features] {
        var output: [SearchResult: Features] = [:]
        for row in rows {
            output[row] = existing[row] ?? Features(
                match: SearchQuality.matchTier(query, row.title), score: SearchQuality.score(query, row),
                language: SearchQuality.chinesePreference(query, row), category: SearchQuality.category(row),
                workKey: SearchQuality.workKeys(row).first ?? "single:\(row.id)", year: row.contentYear)
        }
        return output
    }
    @Published var hostURL: String {
        didSet { UserDefaults.standard.set(hostURL, forKey: Self.hostKey) }
    }
    @Published var hostToken: String {
        didSet { UserDefaults.standard.set(hostToken, forKey: Self.hostTokenKey) }
    }
    @Published var hostTestMessage: String?
    @Published var isTestingHost = false
    /// 设置页请求播放电脑上的极空间测试片。搜索页消费后清空。
    @Published var libraryPlayURL: URL?
    @Published var useEmbeddedEngine: Bool {
        didSet { UserDefaults.standard.set(useEmbeddedEngine, forKey: Self.engineKey) }
    }
    @Published var sources: [SourceConfig] {
        didSet { persistSources() }
    }

    init() {
        var loaded = Self.loadSources()
        // 验收/联调用：`--torznab <endpoint>` 临时注入一个 Torznab 源（不持久化）。
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--torznab"), index + 1 < args.count {
            loaded.insert(SourceConfig(name: "Torznab 测试源", kind: .torznab,
                                       endpoint: args[index + 1]), at: 0)
        }
        hostURL = UserDefaults.standard.string(forKey: Self.hostKey) ?? ""
        hostToken = UserDefaults.standard.string(forKey: Self.hostTokenKey) ?? ""
        useEmbeddedEngine = UserDefaults.standard.object(forKey: Self.engineKey) as? Bool ?? true
        if let index = args.firstIndex(of: "--host"), index + 1 < args.count {
            hostURL = args[index + 1]
            useEmbeddedEngine = false
        }
        if let index = args.firstIndex(of: "--host-token"), index + 1 < args.count {
            hostToken = args[index + 1]
        }
        if args.contains("--embedded") {
            useEmbeddedEngine = true
        }
        if let index = args.firstIndex(of: "--sort"), index + 1 < args.count,
           let option = SortOption(rawValue: args[index + 1]) {
            sortOption = option
        }
        if let index = args.firstIndex(of: "--website"), index + 1 < args.count {
            loaded.insert(SourceConfig(name: "网页测试源", kind: .website,
                                       endpoint: args[index + 1]), at: 0)
        }
        if let index = args.firstIndex(of: "--website-browser"), index + 1 < args.count {
            loaded.insert(SourceConfig(name: "网页浏览器源", kind: .website,
                                       endpoint: args[index + 1], useBrowser: true), at: 0)
        }
        if args.contains("--website-only"), let index = args.firstIndex(of: "--website"), index + 1 < args.count {
            loaded = [SourceConfig(name: "网页测试源", kind: .website, endpoint: args[index + 1])]
        }
        if args.contains("--website-only"), let index = args.firstIndex(of: "--website-browser"), index + 1 < args.count {
            loaded = [SourceConfig(name: "网页浏览器源", kind: .website, endpoint: args[index + 1], useBrowser: true)]
        }
        sources = loaded
    }

    var enabledSources: [SourceConfig] {
        sources.filter { $0.enabled && !$0.endpoint.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var categories: [String] {
        refreshPresentation()
        return cachedCategories
    }

    var displayedResults: [SearchResult] {
        refreshPresentation()
        return cachedRows
    }

    private func refreshPresentation() {
        let q = (rankingQuery ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
        let key = PresentationKey(revision: resultsRevision, query: q, sort: sortOption,
                                  category: categoryFilter, chinese: preferChineseResults,
                                  evidence: EvidenceStore.revision)
        if key == presentationKey && Date().timeIntervalSince(presentationTime) < 1 { return }
        if featureQuery != q { features = [:]; featureQuery = q }
        features = Self.prepare(results, query: q, existing: features)
        cachedCategories = ["全部"] + Set(features.values.map(\.category)).sorted()
        let filtered = categoryFilter == "全部"
            ? results
            : results.filter { features[$0]?.category == categoryFilter }
        // Load persistent evidence once per presentation, never inside a sort comparison.
        let evidence = EvidenceStore.snapshot()
        let scored = filtered.map { row in
            let hash = row.hash ?? Links.magnetHash(row.magnet)
            return (row: row, feature: features[row]!, health: evidence.tier(hash), verified: evidence.isVerified(hash))
        }
        cachedSortNotice = nil
        switch sortOption {
        case .relevance, .verified:
            if sortOption == .verified {
                let count = scored.filter { $0.verified }.count
                cachedSortNotice = count == 0 ? "当前没有已验证资源，暂按推荐排序" : "\(count) 条近期实播通过的资源优先；其余尚未验证"
            }
            cachedRows = scored.sorted { lhs, rhs in
                if sortOption == .verified && lhs.verified != rhs.verified { return lhs.verified }
                if lhs.feature.match != rhs.feature.match { return lhs.feature.match < rhs.feature.match }
                if lhs.health != rhs.health { return lhs.health < rhs.health }
                if preferChineseResults && lhs.feature.language != rhs.feature.language {
                    return lhs.feature.language > rhs.feature.language
                }
                if lhs.feature.score != rhs.feature.score { return lhs.feature.score > rhs.feature.score }
                return lhs.row.id < rhs.row.id
            }.map(\.row)
        case .seeders:
            cachedRows = filtered.sorted { ($0.seeders ?? -1) > ($1.seeders ?? -1) }
        case .newest:
            let missing = filtered.filter { $0.uploadDate == nil }.count
            cachedSortNotice = "按来源提供的上传时间排序，不是影片年份；\(missing) 条日期未知置后"
            cachedRows = filtered.sorted {
                let left = $0.uploadDate ?? .distantPast, right = $1.uploadDate ?? .distantPast
                return left != right ? left > right : $0.id < $1.id
            }
        case .year:
            cachedSortNotice = "按来源或标题标注的作品年份排序，未知或多年份合集置后"
            cachedRows = scored.sorted {
                if $0.feature.year != $1.feature.year { return ($0.feature.year ?? 0) > ($1.feature.year ?? 0) }
                if $0.feature.score != $1.feature.score { return $0.feature.score > $1.feature.score }
                return $0.row.id < $1.row.id
            }.map(\.row)
        case .size:
            cachedRows = filtered.sorted { ($0.size ?? -1) > ($1.size ?? -1) }
        case .title:
            cachedRows = filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        cachedGroups = makeGroups(cachedRows)
        presentationTime = Date()
        presentationKey = key
    }

    func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSearching else { return }
        guard !enabledSources.isEmpty else {
            statusText = "没有可用搜索源，先到设置里添加"
            return
        }

        isSearching = true
        rankingQuery = text
        results = []
        reports = []
        categoryFilter = "全部"
        statusText = "搜索中…"
        let active = enabledSources

        var merged: [SearchResult] = []
        await withTaskGroup(of: SourceOutcome.self) { group in
            for source in active {
                group.addTask { await Self.fetch(source, query: text) }
            }
            for await outcome in group {
                reports.append(outcome.report)
                merged.append(contentsOf: outcome.results)
                let rows = Self.deduplicate(merged)
                let prior = featureQuery == text ? features : [:]
                let prepared = await Task.detached(priority: .userInitiated) {
                    Self.prepare(rows, query: text, existing: prior)
                }.value
                featureQuery = text
                features = prepared
                results = rows
                statusText = "搜索中 · \(reports.count)/\(active.count) 个来源完成 · \(results.count) 条结果"
            }
        }
        isSearching = false

        let succeeded = reports.filter { $0.error == nil }.count
        if merged.isEmpty {
            statusText = "没有结果 · \(succeeded)/\(reports.count) 个来源成功"
        } else {
            statusText = "\(results.count) 条结果 · \(succeeded)/\(reports.count) 个来源成功"
        }
    }

    nonisolated static func fetch(_ source: SourceConfig, query: String) async -> SourceOutcome {
        let start = Date()
        do {
            let results: [SearchResult]
            results = try await SearchSourceClient.search(source, query: query)
            return SourceOutcome(
                report: SourceReport(name: source.name, count: results.count, error: nil,
                                     seconds: Date().timeIntervalSince(start)),
                results: results
            )
        } catch {
            return SourceOutcome(
                report: SourceReport(name: source.name, count: 0,
                                     error: error.localizedDescription,
                                     seconds: Date().timeIntervalSince(start)),
                results: []
            )
        }
    }

    static func deduplicate(_ input: [SearchResult]) -> [SearchResult] {
        let sorted = input.sorted {
            ($0.seeders ?? -1, $0.published ?? .distantPast) > ($1.seeders ?? -1, $1.published ?? .distantPast)
        }
        var seen = Set<String>()
        var output: [SearchResult] = []
        for result in sorted {
            if let key = Links.normalizeHash(result.hash) ?? Links.magnetHash(result.magnet) {
                if seen.contains(key) { continue }
                seen.insert(key)
            }
            output.append(result)
        }
        return output
    }

    var groupedResults: [ResourceGroup] {
        refreshPresentation()
        return cachedGroups
    }

    private func makeGroups(_ rows: [SearchResult]) -> [ResourceGroup] {
        var order: [String] = []
        var groups: [String: [SearchResult]] = [:]
        for row in rows {
            let key = features[row]?.workKey ?? "single:\(row.id)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(row)
        }
        return order.map { key in
            let rows = groups[key] ?? []
            return ResourceGroup(id: key, title: Self.groupTitle(key: key, fallback: rows.first?.title ?? key),
                                 results: rows)
        }
    }

    private static func groupTitle(key: String, fallback: String) -> String {
        guard !key.hasPrefix("single:") else { return fallback }
        let parts = key.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return fallback }
        let year = parts[0]
        let season = parts[1]
        let name = parts[2...].joined(separator: ":")
        var title = name.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        if !year.isEmpty { title += " (\(year))" }
        if !season.isEmpty { title += " · \(season.uppercased())" }
        return title
    }

    func testHost() async {
        guard !hostURL.trimmingCharacters(in: .whitespaces).isEmpty else {
            hostTestMessage = "先填写主机地址"
            return
        }
        isTestingHost = true
        defer { isTestingHost = false }
        do {
            let torrents = try await HostClient.check(host: hostURL, token: hostToken)
            hostTestMessage = "连接成功 · 引擎在线 · \(torrents) 个任务"
        } catch {
            hostTestMessage = error.localizedDescription
        }
    }

    func requestLibraryPlayback() {
        guard let url = HostClient.endpoint(hostURL, path: "/library/bbb.mp4") else {
            hostTestMessage = "先填写电脑播放服务地址"
            return
        }
        libraryPlayURL = url
    }

    func resolvePlayback(for result: SearchResult) async throws -> PlaybackSource {
        if let direct = result.playableDirectURL { return PlaybackSource(url: direct) }
        if let archiveId = result.archiveId, let url = await ArchiveSource.playableURL(archiveId: archiveId) {
            return PlaybackSource(url: url)
        }
        guard let link = Links.magnetLink(for: result) ?? result.torrentURL else {
            throw HostError.engine("这条结果没有可用磁力或种子地址")
        }
        if useEmbeddedEngine {
            return try await EngineClient.resolve(link: link)
        }
        guard link.hasPrefix("magnet:") else {
            throw HostError.engine("主机模式暂不支持 .torrent 链接，请使用内置引擎")
        }
        guard !hostURL.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw HostError.unreachable("还没有配置主机地址")
        }
        let url = try await HostClient.resolve(magnet: link, host: hostURL, token: hostToken)
        return PlaybackSource(url: url)
    }

    func playableURL(for result: SearchResult) async -> URL? {
        if let direct = result.playableDirectURL { return direct }
        if let archiveId = result.archiveId {
            return await ArchiveSource.playableURL(archiveId: archiveId)
        }
        if !hostURL.isEmpty, let magnet = Links.magnetLink(for: result) {
            return try? await HostClient.resolve(magnet: magnet, host: hostURL, token: hostToken)
        }
        return nil
    }

    // MARK: - 持久化

    private static let sourcesKey = "afmc.sources.v1"
    private static let hostKey = "afmc.host"
    private static let hostTokenKey = "afmc.host.token"
    private static let engineKey = "afmc.engine.embedded"

    private func persistSources() {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: Self.sourcesKey)
        }
    }

    private static func loadSources() -> [SourceConfig] {
        let catalog = SourceCatalog.configs()
        guard let data = UserDefaults.standard.data(forKey: sourcesKey),
              let stored = try? JSONDecoder().decode([SourceConfig].self, from: data),
              !stored.isEmpty else {
            return catalog
        }
        var merged: [SourceConfig] = []
        for definition in catalog {
            if let existing = stored.first(where: { $0.id == definition.id }) {
                merged.append(SourceConfig(id: definition.id, name: definition.name,
                                           kind: definition.kind, endpoint: definition.endpoint,
                                           apiKey: existing.apiKey, enabled: existing.enabled,
                                           note: definition.note))
            } else {
                merged.append(definition)
            }
        }
        for custom in stored where !catalog.contains(where: { $0.id == custom.id }) {
            merged.append(custom)
        }
        return merged
    }
}
