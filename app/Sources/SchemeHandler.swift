import Foundation
import ShellstormCore
import WebKit

/// Serves `app://ui` from `Resources/ui` and `app://client` from `Resources/web` — the bundle
/// assemble-app.sh built. Anything `AppURL.resolve` refuses, or that is not on disk, is a 404.
///
/// And ONE dynamic route: `app://client/__paste/<token>/<name>`, a file a page asked to send of what Finder
/// copied (`PreparedPastes`, docs/client-web.md, "A folder") — served ONCE, only to the web view that asked,
/// streamed, and a zip the app made is deleted once served.
/// One streamed paste's stop flag, read from the reading thread.
final class PasteStream: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isStopped: Bool { lock.withLock { stopped } }
    func stop() { lock.withLock { stopped = true } }
}

final class SchemeHandler: NSObject, WKURLSchemeHandler {
    let roots: [String: URL]
    let pastes: PreparedPastes

    init(pastes: PreparedPastes) {
        let res = Bundle.main.resourceURL!
        roots = ["ui": res.appendingPathComponent("ui"), "client": res.appendingPathComponent("web")]
        self.pastes = pastes
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        // A task that is never answered is a load that hangs forever with nothing in any log.
        guard let url = task.request.url else { task.didFailWithError(URLError(.badURL)); return }
        if url.host(percentEncoded: false) == "client", let token = PreparedPastes.token(inPath: url.path(percentEncoded: true)) {
            servePaste(task, url: url, token: token, webView: webView)
            return
        }
        if let file = AppURL.resolve(url.absoluteString, roots: roots), let data = try? Data(contentsOf: file) {
            respond(task, url: url, status: 200, type: AppURL.mimeType(for: file), body: data)
        } else {
            respond(task, url: url, status: 404, type: "text/plain", body: Data("not found".utf8))
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        streams[ObjectIdentifier(task)]?.stop()
    }

    /// The paste streams in flight, by task, so `stop` can end one (the page navigated, the window closed).
    private var streams: [ObjectIdentifier: PasteStream] = [:]

    /// A prepared file, STREAMED: read 1 MiB at a time off the main thread (a `FileHandle`, never a mapping —
    /// a person's own file on a network or removable volume, or one truncated mid-copy, raises SIGBUS through a
    /// mapping and takes the app and its shells with it), each piece handed to WebKit on the main thread, at
    /// most four ahead — so a 1 GiB zip is never in this process whole and the main thread never stalls on it.
    private func servePaste(_ task: any WKURLSchemeTask, url: URL, token: String, webView: WKWebView) {
        guard let entry = pastes.take(token, owner: AnyHashable(ObjectIdentifier(webView))) else {
            respond(task, url: url, status: 404, type: "text/plain", body: Data("not found".utf8))
            return
        }
        guard let handle = try? FileHandle(forReadingFrom: entry.file),
              let size = (try? FileManager.default.attributesOfItem(atPath: entry.file.path)[.size] as? NSNumber)?.int64Value else {
            pastes.finished(entry)
            respond(task, url: url, status: 404, type: "text/plain", body: Data("gone".utf8))
            return
        }
        let type = entry.type.isEmpty ? "application/octet-stream" : entry.type
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type, "Content-Length": String(size), "Cache-Control": "no-store"])!
        task.didReceive(response)
        let key = ObjectIdentifier(task)
        let stream = PasteStream()
        streams[key] = stream
        let pastes = self.pastes
        let finish: @MainActor (Error?) -> Void = { [weak self] error in
            self?.streams[key] = nil
            try? handle.close()
            pastes.finished(entry)
            guard !stream.isStopped else { return }       // a stopped task must not be called again
            if let error { task.didFailWithError(error) } else { task.didFinish() }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // Created at 0 and signalled up to 4: libdispatch TRAPS when a semaphore is freed below the value it
            // was created with, and the read that finds the end (or an error, or a stop) leaves one `wait`
            // unmatched — the live check's first run crashed the app on exactly that (2026-10-02).
            let ahead = DispatchSemaphore(value: 0)
            for _ in 0..<4 { ahead.signal() }
            while !stream.isStopped {
                ahead.wait()
                let chunk: Data
                do { chunk = try handle.read(upToCount: 1 << 20) ?? Data() } catch {
                    DispatchQueue.main.async { MainActor.assumeIsolated { finish(error) } }
                    return
                }
                if chunk.isEmpty { DispatchQueue.main.async { MainActor.assumeIsolated { finish(nil) } }; return }
                DispatchQueue.main.async {
                    if !stream.isStopped { task.didReceive(chunk) }
                    ahead.signal()
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { finish(nil) } }
        }
    }

    private func respond(_ task: any WKURLSchemeTask, url: URL, status: Int, type: String, body: Data) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type, "Content-Length": String(body.count)])!
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }
}
