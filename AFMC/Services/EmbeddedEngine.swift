import Foundation
import TorrServerKit

enum EngineError: LocalizedError {
    case startFailed(String)
    case noVideo
    case timeout
    case api(String)

    var errorDescription: String? {
        switch self {
        case .startFailed(let message): return "内置引擎启动失败：\(message)"
        case .noVideo: return "种子里没有找到视频文件"
        case .timeout: return "等待种子元数据超时，稍后重试或换个资源"
        case .api(let message): return "内置引擎错误：\(message)"
        }
    }
}

/// 内嵌 TorrServer 引擎（B 方案，无需电脑）。
final class EmbeddedEngine {
    static let shared = EmbeddedEngine()
    let port = 8099

    private init() {}

    var isRunning: Bool { TorrserverkitIsRunning() }

    func ensureStarted() throws {
        guard !isRunning else { return }
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AFMCEngine", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let error = TorrserverkitStartServer(Int(port), directory.path)
        guard error.isEmpty else { throw EngineError.startFailed(error) }
    }

    func stop() {
        _ = TorrserverkitStopServer()
    }
}

/// 通过内嵌引擎的本地 HTTP API 解析磁力并返回可播放地址。
enum EngineClient {
    private static var baseURL: URL {
        URL(string: "http://127.0.0.1:\(EmbeddedEngine.shared.port)")!
    }

    static func resolve(link: String) async throws -> PlaybackSource {
        try Task.checkCancellation()
        try EmbeddedEngine.shared.ensureStarted()
        return try await resolve(link: link, baseURL: baseURL, session: .shared)
    }

    // Injectable transport keeps the real add/get protocol covered by offline regressions.
    static func resolve(link: String, baseURL: URL, session: URLSession,
                        timeout: TimeInterval = 90) async throws -> PlaybackSource {
        try Task.checkCancellation()
        let added = try await post("/torrents", ["action": "add", "link": link, "save_to_db": false],
                                   baseURL: baseURL, session: session)
        guard let torrent = try JSONSerialization.jsonObject(with: added) as? [String: Any],
              let hash = Links.normalizeHash(torrent["hash"] as? String) else {
            throw EngineError.api("添加种子后未返回有效哈希")
        }
        if let requested = Links.magnetHash(link), requested != hash {
            throw EngineError.api("引擎返回的资源与所选磁力不一致")
        }
        let deadline = Date().addingTimeInterval(timeout)
        var current = torrent
        while true {
            try Task.checkCancellation()
            if let source = try playbackSource(torrent: current, expectedHash: hash, baseURL: baseURL) {
                return source
            }
            guard Date() < deadline else { throw EngineError.timeout }
            try await Task.sleep(nanoseconds: 500_000_000)
            let data = try await post("/torrents", ["action": "get", "hash": hash],
                                      baseURL: baseURL, session: session)
            guard let status = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw EngineError.api("种子状态响应无效")
            }
            current = status
        }
    }

    static func connectionSummary(for url: URL) async throws -> String? {
        let parts = url.pathComponents
        guard url.host == "127.0.0.1", parts.count >= 4, parts[1] == "play",
              let hash = Links.normalizeHash(parts[2]) else { return nil }
        let data = try await post("/torrents", ["action": "get", "hash": hash], baseURL: baseURL, session: .shared)
        guard let state = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let peers = (state["active_peers"] as? NSNumber)?.intValue ?? 0
        let speed = (state["download_speed"] as? NSNumber)?.doubleValue ?? 0
        if peers == 0 && speed == 0 { return "尚未收到视频数据 · 请检查网络或尝试其他版本" }
        return "\(peers) 个连接 · " + String(format: "%.0f KB/s", speed / 1024)
    }

    static func playbackSource(torrent: [String: Any], expectedHash: String,
                               baseURL: URL) throws -> PlaybackSource? {
        guard Links.normalizeHash(torrent["hash"] as? String) == expectedHash else {
            throw EngineError.api("种子状态与所选资源不一致")
        }
        guard let files = torrent["file_stats"] as? [[String: Any]], !files.isEmpty else { return nil }
        let videoExtensions = ["mp4", "mkv", "webm", "avi", "mov", "m4v", "ts"]
        let videos: [PlaybackFile] = files.compactMap { file in
            guard let path = file["path"] as? String, let id = file["id"] as? Int,
                  videoExtensions.contains((path as NSString).pathExtension.lowercased()) else { return nil }
            return PlaybackFile(id: id, name: path, size: (file["length"] as? NSNumber)?.int64Value ?? 0,
                                url: baseURL.appendingPathComponent("play/\(expectedHash)/\(id)"))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard let video = videos.max(by: { $0.size < $1.size }) else { throw EngineError.noVideo }
        let subtitles = files.compactMap { file -> SubtitleTrack? in
            guard let path = file["path"] as? String, path.lowercased().hasSuffix(".srt"),
                  let id = file["id"] as? Int else { return nil }
            return SubtitleTrack(id: "\(expectedHash)-\(id)", name: subtitleName(path),
                                 url: baseURL.appendingPathComponent("play/\(expectedHash)/\(id)"))
        }
        return PlaybackSource(url: video.url, subtitles: subtitles, files: videos, hash: expectedHash)
    }

    private static func subtitleName(_ path: String) -> String {
        let file = path.split(separator: "/").last.map(String.init) ?? path
        let parts = file.split(separator: ".")
        if parts.count >= 3 {
            return String(parts[parts.count - 2])
        }
        return file
    }

    private static func post(_ path: String, _ payload: [String: Any],
                             baseURL: URL, session: URLSession) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw EngineError.api("HTTP \(http.statusCode) \(message.prefix(80))")
        }
        return data
    }
}
