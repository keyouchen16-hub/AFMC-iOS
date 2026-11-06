import Foundation

/// 播放证据：记录实际起播过的资源（对应 Windows 的“已验证起播”）。
enum EvidenceStore {
    private static let key = "afmc.evidence.decoded.v2"
    private(set) static var revision = 0

    struct Snapshot {
        let verified: [String: Double]
        let health: [String: Any]
        let now: Double

        func isVerified(_ value: String?) -> Bool {
            guard let value, let stamp = verified[value] else { return false }
            return now - stamp >= 0 && now - stamp < 7 * 24 * 60 * 60
        }

        func tier(_ value: String?) -> Int {
            guard let value, let entry = health[value] as? [String: Any],
                  let stamp = entry["time"] as? Double, now - stamp >= 0, now - stamp < 1800 else { return 2 }
            switch entry["state"] as? String {
            case "played": return 0
            case "decoded": return 1
            case "failed": return 3
            default: return 2
            }
        }
    }

    static func snapshot() -> Snapshot {
        Snapshot(verified: load(), health: UserDefaults.standard.dictionary(forKey: "afmc.health.v1") ?? [:],
                 now: Date().timeIntervalSince1970)
    }

    private static func load() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
    }

    static func markVerified(_ value: String) {
        guard !value.isEmpty else { return }
        var map = load()
        map[value] = Date().timeIntervalSince1970
        UserDefaults.standard.set(map, forKey: key)
        record(value, state: "played")
    }

    static func isVerified(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        guard let stamp = load()[value] else { return false }
        let age = Date().timeIntervalSince1970 - stamp
        return age >= 0 && age < 7 * 24 * 60 * 60
    }

    static func clear(_ value: String) {
        revision += 1
        var map = load()
        map.removeValue(forKey: value)
        var health = UserDefaults.standard.dictionary(forKey: "afmc.health.v1") ?? [:]
        health.removeValue(forKey: value)
        UserDefaults.standard.set(health, forKey: "afmc.health.v1")
        UserDefaults.standard.set(map, forKey: key)
    }

    static func date(_ value: String?) -> Date? {
        guard let value, let stamp = load()[value] else { return nil }
        return Date(timeIntervalSince1970: stamp)
    }
    // Mirrors Windows PlaybackHealth: recent evidence expires after 30 minutes.
    static func record(_ value: String, state: String, seconds: Double? = nil) {
        guard !value.isEmpty else { return }
        revision += 1
        var entries = UserDefaults.standard.dictionary(forKey: "afmc.health.v1") ?? [:]
        var entry: [String: Any] = ["state": state, "time": Date().timeIntervalSince1970]
        if let seconds { entry["seconds"] = seconds }
        entries[value] = entry
        UserDefaults.standard.set(entries, forKey: "afmc.health.v1")
    }

    static func recent(_ value: String?) -> [String: Any]? {
        guard let value, let entries = UserDefaults.standard.dictionary(forKey: "afmc.health.v1"),
              let entry = entries[value] as? [String: Any], let time = entry["time"] as? Double,
              Date().timeIntervalSince1970 - time >= 0,
              Date().timeIntervalSince1970 - time < 1800 else { return nil }
        return entry
    }

    static func tier(_ value: String?) -> Int {
        switch recent(value)?["state"] as? String {
        case "played": return 0
        case "decoded": return 1
        case "failed": return 3
        default: return 2
        }
    }

    static func label(_ value: String?) -> String {
        switch recent(value)?["state"] as? String {
        case "played": return "近期实播通过"
        case "decoded": return "已解码首帧 · 持续播放未验证"
        case "failed": return "近期试播未通过"
        default: return "尚未验证播放"
        }
    }
}
