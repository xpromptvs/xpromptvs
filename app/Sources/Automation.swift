#if RDEV_DEV_BUILD
import AppKit
import Network
import WebKit

/// DEV BUILDS ONLY — compiled out of `-c opt` (gate-app-release.sh asserts the string RDEV_APP_AUTOMATION
/// is absent from the release executable). The replacement for Playwright's `_electron`, which
/// cannot attach to an app's WKWebView. Loopback only; enabled only by RDEV_APP_AUTOMATION=<port>.
@MainActor
final class Automation {
    private let listener: NWListener
    private weak var delegate: AppDelegate?
    private var consoleLines: [ObjectIdentifier: [String]] = [:]
    private var holdPattern: String?
    private var traceObserver: CFRunLoopObserver?
    private var traceSamples: [[String: Any]] = []
    private var pairingWaiters: [CheckedContinuation<Void, Never>] = []
    private let consoleSink = ConsoleSink()

    static func startIfRequested(delegate: AppDelegate) -> Automation? {
        guard let raw = ProcessInfo.processInfo.environment["RDEV_APP_AUTOMATION"],
              let port = UInt16(raw).flatMap({ NWEndpoint.Port(rawValue: $0) }) else { return nil }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        guard let listener = try? NWListener(using: params) else { fatalError("automation: cannot bind \(raw)") }
        let a = Automation(listener: listener, delegate: delegate)
        listener.newConnectionHandler = { conn in Task { @MainActor in a.accept(conn) } }
        listener.start(queue: .main)
        print("[automation] listening on 127.0.0.1:\(raw)")
        return a
    }

    private init(listener: NWListener, delegate: AppDelegate) {
        self.listener = listener; self.delegate = delegate
        consoleSink.onLine = { [weak self] web, line in self?.consoleLines[ObjectIdentifier(web), default: []].append(line) }
    }

    /// Called by WebViewFactory for every new web view.
    func instrument(_ ucc: WKUserContentController, kind: WindowKind) {
        ucc.add(consoleSink, contentWorld: .page, name: "automationConsole")
        var source = """
        (() => { const h = window.webkit.messageHandlers.automationConsole;
          for (const k of ["log","info","warn","error","debug"]) { const o = console[k].bind(console);
            console[k] = (...a) => { try { h.postMessage(k + ": " + a.map(String).join(" ")); } catch {} o(...a); }; }
          addEventListener("error", e => h.postMessage("pageerror: " + e.message));
          addEventListener("unhandledrejection", e => h.postMessage("pageerror: " + String(e.reason))); })();
        """
        if kind == .client, let p = holdPattern {
            source += """
            (() => { const re = new RegExp(\(BridgeScripts.json(p))); const Real = window.WebSocket;
              function Held(url, protocols) {
                if (!re.test(String(url))) return new Real(url, protocols);
                const t = new EventTarget(); Object.assign(t, { url: String(url), readyState: 0, protocol: "",
                  bufferedAmount: 0, binaryType: "blob", send() {}, close() { t.readyState = 3; } });
                return t;
              }
              Object.assign(Held, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 });
              Held.prototype = Real.prototype; window.WebSocket = Held; })();
            """
        }
        ucc.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .main)
        var buffer = Data()
        func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, error in
                Task { @MainActor in
                    if let data { buffer.append(data) }
                    while let nl = buffer.firstIndex(of: 0x0a) {
                        let line = buffer[buffer.startIndex..<nl]
                        buffer.removeSubrange(buffer.startIndex...nl)
                        await self.handle(Data(line), on: conn)
                    }
                    if done || error != nil { conn.cancel() } else { receive() }
                }
            }
        }
        receive()
    }

    private func handle(_ line: Data, on conn: NWConnection) async {
        let req = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
        let id = req["id"] ?? NSNull()
        var reply: [String: Any] = ["id": id]
        do { reply["ok"] = true; reply["value"] = try await run(req) ?? NSNull() }
        catch {
            reply["ok"] = false
            // A BridgeError's message verbatim — checks assert on it, as they did on IPC rejections.
            // A page exception's OWN message, not WKErrorDomain's "A JavaScript exception occurred".
            reply["error"] = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                ?? (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
        // `isValidJSONObject` FIRST: `data(withJSONObject:)` raises an Objective-C exception on a
        // value it cannot encode, which no Swift `try` catches.
        var out = (JSONSerialization.isValidJSONObject(reply)
                   ? try? JSONSerialization.data(withJSONObject: reply, options: [.fragmentsAllowed]) : nil)
            ?? Data(#"{"ok":false,"error":"unserializable reply"}"#.utf8)
        out.append(0x0a)
        conn.send(content: out, completion: .idempotent)
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    private func traceSample(_ client: ClientWindow, since start: CFTimeInterval) {
        let chrome = client.chrome!
        func marker(_ layer: CALayer) -> CALayer? {
            if abs(layer.opacity - 0.987) < 0.0006 { return layer }
            for sub in layer.sublayers ?? [] { if let found = marker(sub) { return found } }
            return nil
        }
        var sample: [String: Any] = ["win": [chrome.bounds.width, chrome.bounds.height],
                                     "web": [client.webView.frame.width, client.webView.frame.height],
                                     "running": client.zoom.running]
        if let chromeLayer = chrome.layer, let root = client.webView.layer, let m = marker(root) {
            var shown = m.convert(m.bounds, to: chromeLayer)
            var layer = m.superlayer
            while let current = layer, current !== chromeLayer {
                if current.masksToBounds { shown = shown.intersection(current.convert(current.bounds, to: chromeLayer)) }
                layer = current.superlayer
            }
            sample["laid"] = [m.bounds.width + 7, m.bounds.height + 3]
            sample["shown"] = shown.isNull ? [0, 0] : [shown.width + 7, shown.height + 3]
        }
        if let last = traceSamples.last, NSDictionary(dictionary: last.filter { $0.key != "t" }).isEqual(to: sample) { return }
        sample["t"] = (CACurrentMediaTime() - start) * 1000
        traceSamples.append(sample)
    }

    private func window(_ req: [String: Any]) throws -> AppWindow {
        guard let id = (req["window"] as? NSNumber)?.intValue, let w = delegate?.windows.find(id: id) else {
            throw Failure(description: "no such window \(req["window"] ?? "nil")")
        }
        return w
    }

    private func js(_ w: AppWindow, _ body: String, _ args: [String: Any] = [:]) async throws -> Any? {
        let v = try await w.webView.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: .page)
        // Round-trip through JSON so the reply is always serialisable.
        guard let v else { return nil }
        // NaN, Infinity and a Date come back as a non-finite NSNumber / an NSDate, and
        // `data(withJSONObject:)` RAISES on them (an ObjC exception `try` cannot catch): it unwound
        // out of the handler, so no reply was sent and the connection never read again.
        guard JSONSerialization.isValidJSONObject([v]) else {
            throw Failure(description: "unserialisable value (\(type(of: v)))")
        }
        let d = try JSONSerialization.data(withJSONObject: [v], options: [.fragmentsAllowed])
        return (try JSONSerialization.jsonObject(with: d) as? [Any])?.first
    }

    private func run(_ req: [String: Any]) async throws -> Any? {
        guard let delegate else { throw Failure(description: "app is gone") }
        switch req["cmd"] as? String {
        case "restoreApps":
            let error:String? = await withCheckedContinuation { continuation in
                delegate.host.restoreWorkspace { error in continuation.resume(returning:error) }
            }
            if let error {throw Failure(description:error)}
            return true
        case "nativeSimulators":
            return (delegate.nativeSimulators?.windows.values.map { w -> [String: Any] in
                let metrics = w.picture.renderer?.metrics
                return ["source": w.source, "generation": w.generation, "window": w.window.windowNumber,
                        "title": w.window.title, "visible": w.window.isVisible, "minimized": w.window.isMiniaturized,
                        "key": w.window.isKeyWindow, "picture": !w.picture.isHidden, "nativeScrollReady": w.nativeScrollReady,
                        "backingScale": w.window.backingScaleFactor,
                        "pictureRect": [w.picture.pictureRect.minX, w.picture.pictureRect.minY + 40, w.picture.pictureRect.width, w.picture.pictureRect.height],
                        "size": [w.picture.devicePointSize.width, w.picture.devicePointSize.height],
                        "timing": w.picture.renderer?.timing ?? [:], "presented": metrics?.presented ?? 0, "callbackAgeMs": metrics?.callbackAgeMs ?? 0]
            }) ?? []
        case "nativeSimulatorEvent":
            guard let source = req["source"] as? String, let w = delegate.nativeSimulators?.windows[source] else {
                throw Failure(description: "no native simulator")
            }
            switch req["event"] as? String {
            case "resize": w.window.setContentSize(NSSize(width: req["width"] as? Double ?? 402, height: req["height"] as? Double ?? 760))
            case "wheel":
                w.scrollForTest(dx: req["dx"] as? Double ?? 0, dy: req["dy"] as? Double ?? -120)
            case "close": w.window.performClose(nil)
            case "minimize": w.window.miniaturize(nil)
            case "restore": delegate.nativeSimulators?.activate(source: source)
            case "tap":
                let p = w.picture.pictureRect
                let at = w.picture.convert(NSPoint(x: p.minX + p.width * (req["x"] as? Double ?? 0.5),
                                                   y: p.minY + p.height * (req["y"] as? Double ?? 0.5)), to: nil)
                for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: w.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        if type == .leftMouseDown { w.picture.mouseDown(with: e) } else { w.picture.mouseUp(with: e) }
                    }
                }
            case "text": w.picture.insertText(req["text"] as? String ?? "", replacementRange: NSRange(location: NSNotFound, length: 0))
            default: throw Failure(description: "unknown simulator event")
            }
            return true
        case "process":
            return ["pid": getpid(), "active": NSApp.isActive, "bundle": Bundle.main.bundleURL.path] as [String: Any]
        case "windows":
            return delegate.windows.all().map { w -> [String: Any] in
                var value: [String: Any] = ["id": w.id, "kind": w.kind.rawValue, "url": w.webView.url?.absoluteString ?? "", "title": w.window.title,
                 "visible": w.window.isVisible, "minimized": w.window.isMiniaturized, "key": w.window.isKeyWindow]
                if let source = w as? NativeSourceWindow { value.merge(source.sourceKey.json) { _, new in new } }
                return value
            }
        case "eval":
            return try await js(try window(req), req["js"] as? String ?? "return null")
        // AppKit hit testing, not DOM hit testing: a transparent native title bar can otherwise
        // swallow web tabs while every JavaScript click still passes.
        case "sourceScroll":
            guard let source = try window(req) as? NativeSourceWindow,
                  let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                    wheel1: Int32(req["dy"] as? Int ?? 0), wheel2: Int32(req["dx"] as? Int ?? 0), wheel3: 0) else {
                throw Failure(description: "not a source scroll")
            }
            let x = req["x"] as? Double ?? 0.5, y = req["y"] as? Double ?? 0.5
            let local = source.webView.convert(NSPoint(x: source.webView.bounds.width*x, y: source.webView.bounds.height*y), to: nil)
            let screen = source.window.convertPoint(toScreen: local)
            event.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0)-screen.y)
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(source.window.windowNumber))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(source.window.windowNumber))
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(req["phase"] as? Int ?? 0))
            event.setIntegerValueField(CGEventField(rawValue: 123)!, value: Int64(req["momentum"] as? Int ?? 0))
            if let time = req["time"] as? Double { event.timestamp = CGEventTimestamp(time * 1_000_000_000) }
            guard let native = NSEvent(cgEvent: event) else { throw Failure(description: "could not construct native scroll") }
            // CGEvent-created NSEvents have no window identity. Exercise actual phase extraction
            // and bridge delivery at the observer boundary, never fake a physical event-loop claim.
            source.captureNativeScrollForCheck(native, at: NSPoint(x: source.webView.bounds.width*x, y: source.webView.bounds.height*y))
            return ["phase": native.phase.rawValue, "momentum": native.momentumPhase.rawValue,
                    "resolvedWindow": native.window === source.window]
        case "sourceChrome", "sourceButton", "sourceHeaderMenu":
            guard let source = try window(req) as? NativeSourceWindow, let root = source.window.contentView else {
                throw Failure(description: "not a source window")
            }
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let views = descendants(root)
            if req["cmd"] as? String == "sourceButton" {
                guard let label = req["label"] as? String,
                      let button = views.compactMap({ $0 as? NSButton }).first(where: { $0.toolTip == label }) else {
                    throw Failure(description: "source button not found")
                }
                button.performClick(nil); return nil
            }
            if req["cmd"] as? String == "sourceHeaderMenu" {
                guard let header = views.first(where: { String(describing: type(of: $0)) == "SourceHeader" }),
                      let event = NSEvent.mouseEvent(with: .rightMouseDown,
                        location: header.convert(NSPoint(x: 24, y: header.bounds.midY), to: nil),
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: source.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                    throw Failure(description: "source header not found")
                }
                header.rightMouseDown(with: event); return nil
            }
            return ["fullscreen": source.fullscreenCheckState, "buttons": views.compactMap { ($0 as? NSButton)?.toolTip },
                    "labels": views.compactMap { ($0 as? NSTextField).flatMap { $0.isHiddenOrHasHiddenAncestor ? nil : $0.stringValue } }]
        case "clientChrome":
            let w = try window(req)
            guard let client = w as? ClientWindow, let root = w.window.contentView?.superview else {
                throw Failure(description: "not a client window")
            }
            let web = w.webView
            let frame = web.convert(web.bounds, to: root)
            let points = req["points"] as? [[Double]] ?? []
            return ["fullSize": w.window.styleMask.contains(.fullSizeContentView),
                    // WKWebView's layer-hosting view clips again once a lockstep zoom ends (`LockstepZoom`).
                    "webClips": web.subviews.first { String(describing: type(of: $0)) == "WKFlippedView" }?.clipsToBounds as Any,
                    "titleHidden": w.window.titleVisibility == .hidden,
                    "topInset": root.bounds.maxY - frame.maxY,
                    "controls": client.chrome.controls.map { b -> [String: Any] in
                        let r = b.convert(b.bounds, to: client.chrome)
                        return ["x": r.midX, "y": r.midY, "visible": !b.isHiddenOrHasHiddenAncestor]
                    },
                    "webHits": points.map { p -> Bool in
                        guard p.count == 2 else { return false }
                        let local = NSPoint(x: p[0], y: web.isFlipped ? p[1] : web.bounds.height - p[1])
                        guard let hit = root.hitTest(web.convert(local, to: root)) else { return false }
                        return hit === web || hit.isDescendant(of: web)
                    }]
        case "click":
            return try await js(try window(req), """
                const el = window.__rdevClientRoot?.querySelector(selector) ?? document.querySelector(selector); if (!el) throw new Error("no element " + selector);
                el.click(); return true;
                """, ["selector": req["selector"] as? String ?? ""])
        case "fill":
            return try await js(try window(req), """
                const el = window.__rdevClientRoot?.querySelector(selector) ?? document.querySelector(selector); if (!el) throw new Error("no element " + selector);
                el.focus(); el.value = value;
                el.dispatchEvent(new Event("input", { bubbles: true })); el.dispatchEvent(new Event("change", { bubbles: true }));
                return true;
                """, ["selector": req["selector"] as? String ?? "", "value": req["value"] as? String ?? ""])
        case "console":
            let w = try window(req)
            let key = ObjectIdentifier(w.webView)
            defer { consoleLines[key] = [] }
            return consoleLines[key] ?? []
        // The Dock icon clicked (`applicationShouldHandleReopen`): This Mac back when closed, else `activate`.
        case "activate":
            // A check launched directly from a shell lacks the Dock's foreground activation token.
            // Keep this explicit automation action separate from passive document/frame arrival.
            if req["window"] != nil { try window(req).show() } else { delegate.reopen() }
            NSApp.activate(ignoringOtherApps: true)
            return nil
        // The Dock's badge (`AppWindows.setBell`): its text, or null with none.
        case "dockBadge": return NSApp.dockTile.badgeLabel
        case "minimize": try window(req).window.miniaturize(nil); return nil
        // `frame {x, y, width, height}` — TOP-LEFT origin in points from the primary screen's top-left,
        // so a measurement can keep a window off the source it captures (`scripts/app-latency.sh`).
        // Read only this process's requested window in the same global coordinates as `frame`.
        // WKWebView's screenX/outerWidth can be zero and cannot prove native marker placement.
        case "displayState":
            var displays = [CGDirectDisplayID](repeating: 0, count: 32)
            var count: UInt32 = 0
            guard CGGetOnlineDisplayList(32, &displays, &count) == .success else {
                throw Failure(description: "display inventory unavailable")
            }
            return displays.prefix(Int(count)).map { id -> [String: Any] in
                let r = CGDisplayBounds(id)
                return ["id": id, "active": CGDisplayIsActive(id) != 0, "asleep": CGDisplayIsAsleep(id) != 0,
                        "bounds": [r.minX,r.minY,r.width,r.height]]
            }
        case "windowFrame":
            let w = try window(req)
            guard let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]],
                  let row = rows.first(where: {
                      ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid() &&
                      ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == w.window.windowNumber
                  }),
                  let value = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: value as CFDictionary) else {
                throw Failure(description: "own window has no native frame")
            }
            return ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height,
                    "visible": row[kCGWindowIsOnscreen as String] as? Bool ?? false,
                    "window": w.window.windowNumber, "pid": getpid()] as [String: Any]
        case "frame":
            let w = try window(req)
            let n = { (k: String) in (req[k] as? NSNumber)?.doubleValue }
            guard let x = n("x"), let y = n("y"), let width = n("width"), let height = n("height"),
                  let primary = NSScreen.screens.first else { throw Failure(description: "frame needs x, y, width, height") }
            w.window.setFrame(NSRect(x: x, y: primary.frame.maxY - y - height, width: width, height: height), display: true)
            return nil
        case "close": try window(req).close(); return nil
        // The PERSON's macOS full screen — the green button — as opposed to one a page asks for
        // (`e2e/app-fullscreen-check.mjs`). `isFullScreen` reads the window's own state.
        case "zoomClient":
            guard let client = try window(req) as? ClientWindow else { throw Failure(description: "not a client") }
            client.zoom.mutation = req["mutation"] as? String
            client.animateZoom()
            return nil
        // `resizeTrace {window, on}` — at every Core Animation flush (a run-loop observer ordered after CA's
        // own), the window's content size beside the PAGE's: the size it was laid out for and the size shown,
        // read from a layer the check adds (`position: fixed`, 100vw−7 × 100vh−3, `will-change: transform`,
        // opacity .987) — shown is that layer cut by every masking ancestor. `on: false` returns the samples,
        // one per change. `LockstepZoom`'s check (`e2e/app-chrome-check.mjs`).
        case "resizeTrace":
            guard let client = try window(req) as? ClientWindow else { throw Failure(description: "not a client") }
            if let observer = traceObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            traceObserver = nil
            guard req["on"] as? Bool == true else { return traceSamples }
            traceSamples = []
            let start = CACurrentMediaTime()
            let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
            let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, Int(Int32.max)) { [weak self, weak client] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let client else { return }
                    self.traceSample(client, since: start)
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            traceObserver = observer
            return nil
        case "toggleFullScreen": try window(req).window.toggleFullScreen(nil); return nil
        case "isFullScreen": return try window(req).window.styleMask.contains(.fullScreen)
        // SIGKILL a window's WEB CONTENT process, as a crash or a jetsam would, so a check can see
        // what `webViewWebContentProcessDidTerminate` does (`e2e/app-push-check.mjs` arm 6). NOT
        // WebKit's `_killWebContentProcess`: a client-requested termination does not reach that
        // delegate method (measured — the dashboard hung blank either way). The pid is WebKit's
        // private `_webProcessIdentifier`; dev builds only, like everything in this file.
        case "killWebContent":
            let web = try window(req).webView
            guard let pid = (web.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else {
                throw Failure(description: "no web content process to kill")
            }
            Darwin.kill(pid, SIGKILL)
            return Int(pid)
        // A REAL Edit ▸ Paste into a window's web view — WebKit's own paste of the general pasteboard, as ⌘V gives
        // it, so a check can see what WebKit hands the page for what Finder copied (`e2e/app-paste-folder-check.mjs`).
        // The element the page focused takes it. True when the web view took the action.
        case "paste":
            let w = try window(req)
            w.window.makeKeyAndOrderFront(nil)
            return NSApp.sendAction(#selector(NSText.paste(_:)), to: w.webView, from: nil)
        case "bridge": return try await delegate.automationBridge(op: req["op"] as? String ?? "", args: req["args"] as? [Any] ?? [])
        case "holdWebSocket": holdPattern = req["pattern"] as? String; return nil
        // Hold every connect attempt BEFORE it resolves its pairing (no client window yet), until
        // `releasePairing`. `pendingConnects` reports the attempts and how many sit in the hold.
        case "holdPairing":
            delegate.ui.attempts.beforePairing = { [weak self] in
                await withCheckedContinuation { k in
                    guard let self else { k.resume(); return }
                    self.pairingWaiters.append(k)
                }
            }
            return nil
        case "releasePairing":
            delegate.ui.attempts.beforePairing = nil
            let waiters = pairingWaiters; pairingWaiters = []
            for k in waiters { k.resume() }
            return waiters.count
        case "pendingConnects":
            return ["pending": delegate.ui.attempts.pendingCount, "heldPairings": pairingWaiters.count]
        case "quit":
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return nil
        default: throw Failure(description: "unknown cmd \(req["cmd"] ?? "nil")")
        }
    }
}

private final class ConsoleSink: NSObject, WKScriptMessageHandler {
    var onLine: ((WKWebView, String) -> Void)?
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        if let web = m.webView, let line = m.body as? String { onLine?(web, line) }
    }
}
#endif
