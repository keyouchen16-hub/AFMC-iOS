import Foundation

/// 本地字幕文件按资源持久化（导入后下次自动加载）。
enum SubtitleStore {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Subtitles", isDirectory: true)
    }

    private static func fileURL(_ key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("srt")
    }

    static func save(_ data: Data, for key: String) {
        guard !key.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(key), options: .atomic)
    }

    static func load(_ key: String?) -> Data? {
        guard let key, !key.isEmpty else { return nil }
        return try? Data(contentsOf: fileURL(key))
    }

    static func clear(_ key: String) {
        try? FileManager.default.removeItem(at: fileURL(key))
    }
}
