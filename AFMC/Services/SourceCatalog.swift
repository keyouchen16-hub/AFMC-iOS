import Foundation

struct SourceDefinition {
    let id: String
    let name: String
    let kind: SourceKind
    let endpoint: String
    let description: String
    let enabledByDefault: Bool
}

/// 与 Windows 端 `SiteSources.Catalog` 对齐的内置来源目录。
enum SourceCatalog {
    static let all: [SourceDefinition] = [
        .init(id: "global-piratebay", name: "海盗湾", kind: .piratebay,
              endpoint: "https://apibay.org",
              description: "APIBay 直连搜索 · 单批最多 100 条 · 与 TPB 镜像结果按哈希去重",
              enabledByDefault: true),
        .init(id: "global-knaben", name: "Knaben", kind: .knaben,
              endpoint: "https://api.knaben.org",
              description: "综合聚合 · 官方 API v2 · 显示原始索引来源",
              enabledByDefault: true),
        .init(id: "global-bitsearch", name: "BitSearch", kind: .bitsearch,
              endpoint: "https://bitsearch.eu",
              description: "综合搜索 · 官方 API · 免费额度 200 请求/IP/天",
              enabledByDefault: true),
        .init(id: "global-nyaa", name: "Nyaa", kind: .nyaa,
              endpoint: "https://nyaa.si",
              description: "动漫、音乐及东亚资源 · 官方 RSS · 单次最多 75 条",
              enabledByDefault: true),
        .init(id: "global-dmhy", name: "动漫花园", kind: .dmhy,
              endpoint: "https://share.dmhy.org",
              description: "中文动漫、音乐等 · 关键词 RSS 单批 · 做种/大小未知不估算",
              enabledByDefault: true),
        .init(id: "global-torrentscsv", name: "Torrents.csv", kind: .torrentscsv,
              endpoint: "https://torrents-csv.com",
              description: "综合资源 · 公开 API · 游标翻页，最多 3 页",
              enabledByDefault: true),
        .init(id: "global-tokyotosho", name: "Tokyo Toshokan", kind: .tokyotosho,
              endpoint: "https://www.tokyotosho.info",
              description: "日系动漫、音乐及其他资源 · 关键词 RSS · 做种未知时不估算",
              enabledByDefault: true),
        .init(id: "global-foss", name: "FOSS Torrents", kind: .foss,
              endpoint: "https://fosstorrents.com",
              description: "开源软件、系统与游戏目录 · 标题关键词匹配 · 单批最多 100 条",
              enabledByDefault: true),
        .init(id: "global-linuxtracker", name: "LinuxTracker", kind: .linuxtracker,
              endpoint: "https://linuxtracker.org",
              description: "Linux 与开源软件 · 关键词搜索最多 3 页 · 仅使用本站报告做种",
              enabledByDefault: true),
        .init(id: "global-limetorrents", name: "LimeTorrents", kind: .limetorrents,
              endpoint: "https://www.limetorrents.fun",
              description: "综合资源 · 真实结果表及哈希 · 排除广告",
              enabledByDefault: true),
        .init(id: "site-zhongzilou", name: "种子楼", kind: .zhongzilou,
              endpoint: "https://m.zhongzilou.com",
              description: "真实聚合 · 标题、大小、时间及磁力链接",
              enabledByDefault: true),
        .init(id: "site-tpb", name: "TPB Proxy", kind: .tpbproxy,
              endpoint: "https://www.tpbproxypirate.com",
              description: "真实聚合 · 经入口公布的 thepiratebay.party 镜像查询",
              enabledByDefault: true),
        .init(id: "global-cilixiong", name: "磁力熊", kind: .cilixiong,
              endpoint: "https://www.cilixiong.cc",
              description: "电影/剧集 · 中文片名 · 每次前 8 部的磁力版本与海报",
              enabledByDefault: true),
        .init(id: "global-eztv", name: "EZTV", kind: .eztv,
              endpoint: "https://eztvx.to/api/",
              description: "剧集 · 剧名经 TVmaze 匹配 IMDb 后检索 · 中文别名可能无结果",
              enabledByDefault: true),
        .init(id: "official-debian", name: "Debian 官方", kind: .debian,
              endpoint: "https://www.debian.org/CD/torrent-cd/",
              description: "官方稳定版系统镜像 · amd64/arm64 CD/DVD 种子目录 · 非综合搜索源",
              enabledByDefault: true),
    ]

    static func configs() -> [SourceConfig] {
        all.map { definition in
            SourceConfig(id: definition.id, name: definition.name, kind: definition.kind,
                         endpoint: definition.endpoint, enabled: definition.enabledByDefault,
                         note: definition.description)
        }
    }
}
