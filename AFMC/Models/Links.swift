import Foundation

enum Links {
    /// 对齐 Windows：解析 xt 参数，支持十六进制与 Base32 的 v1 哈希。
    static func magnetHash(_ magnet: String?) -> String? {
        guard let magnet, magnet.count <= 16384,
              !magnet.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: magnet), components.scheme?.lowercased() == "magnet" else { return nil }
        for item in components.queryItems ?? [] where item.name.lowercased() == "xt" {
            guard let value = item.value, value.lowercased().hasPrefix("urn:btih:") else { continue }
            if let hash = normalizeHash(String(value.dropFirst(9))) { return hash }
        }
        return nil
    }

    static func normalizeHash(_ value: String?) -> String? {
        guard var hash = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if hash.lowercased().hasPrefix("btih:") { hash = String(hash.dropFirst(5)) }
        if hash.count == 40 && hash.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) {
            return hash.lowercased()
        }
        guard hash.count == 32 else { return nil }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var accumulator = 0, bits = 0
        var bytes: [UInt8] = []
        for character in hash.uppercased() {
            guard let digit = alphabet.firstIndex(of: character) else { return nil }
            accumulator = (accumulator << 5) | digit
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((accumulator >> bits) & 255))
                accumulator &= (1 << bits) - 1
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func magnetLink(for result: SearchResult) -> String? {
        if let magnet = result.magnet { return magnet }
        guard let hash = result.hash else { return nil }
        return "magnet:?xt=urn:btih:\(hash)"
    }
}

enum SourceError: LocalizedError {
    case badEndpoint
    case http(Int)
    case parse
    case api(String)

    var errorDescription: String? {
        switch self {
        case .badEndpoint: return "地址无效"
        case .http(let code): return "HTTP \(code)"
        case .parse: return "解析失败"
        case .api(let message): return message
        }
    }
}
