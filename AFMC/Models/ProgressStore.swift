import Foundation

/// 每部资源的播放进度记忆（UserDefaults）。
enum ProgressStore {
    private static func key(_ value: String) -> String { "afmc.progress.\(value)" }

    static func load(_ value: String) -> Double? {
        UserDefaults.standard.object(forKey: key(value)) as? Double
    }

    static func save(_ value: String, _ seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        UserDefaults.standard.set(seconds, forKey: key(value))
    }

    static func clear(_ value: String) {
        UserDefaults.standard.removeObject(forKey: key(value))
    }
}
