import Foundation
import WebKit

/// 每次请求拥有独立 WebView 和超时任务，避免多源搜索互相覆盖。
@MainActor
final class BrowserPageLoader {
    static let shared = BrowserPageLoader()

    func loadHTML(_ url: URL, settle: TimeInterval = 2, timeout: TimeInterval = 22) async throws -> String {
        let request = BrowserPageRequest(settle: settle, timeout: timeout)
        return try await request.load(url)
    }
}

@MainActor
private final class BrowserPageRequest: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<String, Error>?
    private var webView: WKWebView?
    private var timeoutTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private let settle: TimeInterval
    private let timeout: TimeInterval

    init(settle: TimeInterval, timeout: TimeInterval) {
        self.settle = max(0, settle)
        self.timeout = max(0.01, timeout)
    }

    func load(_ url: URL) async throws -> String {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let config = WKWebViewConfiguration()
                config.defaultWebpagePreferences.allowsContentJavaScript = true
                let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
                webView = view
                view.navigationDelegate = self
                if url.isFileURL {
                    view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
                } else {
                    view.load(URLRequest(url: url, timeoutInterval: timeout))
                }
                timeoutTask = Task { [weak self, timeout] in
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                    catch { return }
                    self?.finish(.failure(SourceError.api("浏览器加载超时")))
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        captureTask?.cancel()
        timeoutTask = nil
        captureTask = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        continuation.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        captureTask?.cancel()
        captureTask = Task { [weak self, weak webView, settle] in
            do { try await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000)) }
            catch { return }
            guard let self, let webView, self.continuation != nil else { return }
            do {
                guard let html = try await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String,
                      !html.isEmpty else { throw SourceError.parse }
                self.finish(.success(html))
            } catch { self.finish(.failure(error)) }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
}
