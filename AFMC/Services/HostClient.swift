import Foundation

/// 主机桥接客户端（M2-A）。服务端实现见 `host/afmc_host.py`。
enum HostError: LocalizedError {
    case unauthorized
    case engineTimeout
    case engine(String)
    case unreachable(String)
    case localNetwork
    case badResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "主机令牌不正确"
        case .engineTimeout: return "主机等待种子元数据超时，稍后重试或换个资源"
        case .engine(let message): return "主机引擎错误：\(message)"
        case .unreachable(let message): return "连不上主机：\(message)"
        case .localNetwork: return "无法访问本地网络：请在 设置 → AFMC → 本地网络 里允许"
        case .badResponse: return "主机返回了无法识别的响应"
        }
    }
}

enum HostClient {
    private struct ErrorBody: Decodable { let error: String }
    private struct ResolveResponse: Decodable {
        let url: String
        let name: String?
        let size: Int64?
    }

    static func check(host: String, token: String = "") async throws -> Int {
        guard let url = endpoint(host, path: "/health") else { throw SourceError.badEndpoint }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        if !token.isEmpty { request.setValue(token, forHTTPHeaderField: "X-AFMC-Token") }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw HostError.localNetwork
        } catch {
            throw HostError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw HostError.badResponse }
        if http.statusCode == 401 { throw HostError.unauthorized }
        guard http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["status"] as? String == "ok" else {
            throw HostError.engine("HTTP \(http.statusCode)")
        }
        return object["torrents"] as? Int ?? 0
    }

    static func resolve(magnet: String, host: String, token: String = "") async throws -> URL {
        guard let url = endpoint(host, path: "/resolve") else { throw SourceError.badEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { request.setValue(token, forHTTPHeaderField: "X-AFMC-Token") }
        request.httpBody = try JSONEncoder().encode(["magnet": magnet])
        request.timeoutInterval = 70

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw HostError.localNetwork
        } catch {
            throw HostError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw HostError.badResponse }
        if http.statusCode != 200 {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? ""
            switch http.statusCode {
            case 401: throw HostError.unauthorized
            case 504: throw HostError.engineTimeout
            default: throw HostError.engine(message.isEmpty ? "HTTP \(http.statusCode)" : message)
            }
        }
        guard let decoded = try? JSONDecoder().decode(ResolveResponse.self, from: data) else {
            throw HostError.badResponse
        }
        guard let playURL = URL(string: decoded.url) else { throw HostError.badResponse }
        return playURL
    }

    static func endpoint(_ host: String, path: String) -> URL? {
        var text = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard var components = URLComponents(string: text) else { return nil }
        components.path = path
        return components.url
    }
}
