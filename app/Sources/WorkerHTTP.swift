import Foundation
import ShellstormCore

/// The HTTP half of `__rdevShell.request` — see `WorkerRequest` for WHAT may be asked. This is HOW:
/// an ephemeral session with no cookies, no cache and no credential store; bodies are text, capped
/// both ways; a redirect is returned as the answer it is and followed NOWHERE.
final class WorkerHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = WorkerHTTP()

    struct Answer: Sendable { let status: Int; let body: String; let contentType: String? }

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCredentialStorage = nil
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    func perform(url: URL, method: String, body: String?) async -> Result<Answer, BridgeError> {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpShouldHandleCookies = false
        if let body {
            req.httpBody = Data(body.utf8)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (bytes, response) = try await session.bytes(for: req)
            guard let http = response as? HTTPURLResponse else { return .failure(BridgeError("request failed: not HTTP")) }
            if http.expectedContentLength > Int64(WorkerRequest.maxResponseBody) {
                bytes.task.cancel()
                return .failure(BridgeError("request failed: response too large"))
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > WorkerRequest.maxResponseBody {
                    bytes.task.cancel()
                    return .failure(BridgeError("request failed: response too large"))
                }
            }
            return .success(Answer(status: http.statusCode, body: String(decoding: data, as: UTF8.self),
                                   contentType: http.value(forHTTPHeaderField: "Content-Type")))
        } catch {
            // The reason is the transport's, never the request: nothing about the body or the path
            // (a room token, a root id) reaches a log or the page from here.
            return .failure(BridgeError("request failed: \((error as? URLError)?.code.rawValue ?? -1)"))
        }
    }

    // A redirect is followed NOWHERE: `nil` hands the 3xx itself back as the response.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        WorkerRequest.followsRedirects ? request : nil
    }
}
