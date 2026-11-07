import Foundation
import ShellstormCore

/// The page-facing API, injected at document start. SAME names and shapes as the retired Electron
/// preloads (`desktop/src/preload/{ui,client}.ts`, in git history), so neither the dashboard nor the
/// web client changes.
enum BridgeScripts {
    static let uiOps = ["launchStartup", "setLaunchStartup", "dismissDashboard", "state", "share", "settings", "setAutoShare", "setAllowRemoteUpdates", "smoothScroll", "setSmoothScroll",
                        "stop", "curtain", "openClient", "openLocal", "openSharing",
                        "openPermission", "requestPermission", "sessions", "connectSession", "cancelConnect",
                        "e2eState", "e2eSignIn", "e2eCreatePasskey", "e2eAuthorise", "e2ePending",
                        "e2eCapabilities", "adoptStart", "adoptStatus", "adoptCancel",
                        "addDeviceStart", "addDeviceConfirm", "addDeviceCancel",
                        "e2eForget", "accountState", "subscribe", "setChromeGap"]

    static let ui: String = """
    (() => {
      const h = window.webkit.messageHandlers.rdevApp;
      const call = (op) => (...args) => h.postMessage({ op, args });
      const api = {};
      for (const op of \(json(uiOps))) api[op] = call(op);
      const listeners = new Set();
      api.onClientClosed = (cb) => { listeners.add(cb); return () => listeners.delete(cb); };
      // Native → page: AppDelegate evaluates `__rdevAppClientClosed(<id>)` when a client closes.
      Object.defineProperty(window, "__rdevAppClientClosed", {
        value: (id) => { for (const l of listeners) { try { l(id); } catch (e) { console.error(e); } } },
      });
      // Native → page: `SmoothScrollSetting` evaluates `__rdevSmoothScroll(<bool>)` in EVERY window on
      // every change of the app's one smooth-scrolling value, whichever window made it.
      const smooth = new Set();
      api.onSmoothScroll = (cb) => { smooth.add(cb); return () => smooth.delete(cb); };
      Object.defineProperty(window, "__rdevSmoothScroll", {
        value: (on) => { for (const cb of smooth) { try { cb(on === true); } catch (e) { console.error(e); } } },
      });
      // Native → page: StatePublisher evaluates `__rdevAppState(<snapshot>)` on every change.
      const subscribers = new Set();
      Object.defineProperty(window, "__rdevAppState", {
        value: (s) => { for (const cb of subscribers) { try { cb(s); } catch (e) { console.error(e); } } },
      });
      // AFTER the op loop: overrides the plain `subscribe` wrapper. Delivers the current snapshot at once.
      // A REFUSED first call is logged and retried ONCE, shortly: until a change happens to be
      // pushed, that snapshot is the only way the page learns anything (`e2e/app-push-check.mjs` arm 5).
      api.subscribe = (cb) => {
        subscribers.add(cb);
        const deliver = (s) => { if (s && subscribers.has(cb)) cb(s); };
        call("subscribe")().then(deliver, (e) => {
          console.error("[rdevApp] subscribe failed, retrying once:", e);
          setTimeout(() => {
            if (!subscribers.has(cb)) return;
            call("subscribe")().then(deliver, (e2) => console.error("[rdevApp] subscribe retry failed:", e2));
          }, 250);
        });
        return () => subscribers.delete(cb);
      };
      Object.defineProperty(window, "rdevApp", { value: Object.freeze(api), enumerable: true });
    })();
    """

    /// NOT `__rdev` — `web/src/lib/debug.ts` assigns that global wholesale.
    static func client(_ env: ShellEnvironment) -> String { """
    (() => {
      const h = window.webkit.messageHandlers.rdevShell;
      // Native → page, as on the dashboard: every change of the app's one smooth-scrolling value.
      const smooth = new Set();
      Object.defineProperty(window, "__rdevSmoothScroll", {
        value: (on) => { for (const cb of smooth) { try { cb(on === true); } catch (e) { console.error(e); } } },
      });
      // Native → page: `StatePublisher` evaluates `__rdevSharing(<bool>)` in every client window when the app
      // starts or stops SHARING (This Mac's status bar: "remote access enabled").
      const sharing = new Set();
      Object.defineProperty(window, "__rdevSharing", {
        value: (on) => { for (const cb of sharing) { try { cb(on === true); } catch (e) { console.error(e); } } },
      });
      // Native → page: `ClientWindow` evaluates `__rdevFullscreenLeft()` when the person leaves the
      // full screen the page asked for (the green button), so the page's own mode follows it out.
      const fsLeft = new Set();
      Object.defineProperty(window, "__rdevFullscreenLeft", {
        value: () => { for (const cb of fsLeft) { try { cb(); } catch (e) { console.error(e); } } },
      });
      // THE LOCAL WINDOW'S SOCKET (docs/desktop-app.md, "The bridge socket"). Its OWN handler, and one
      // with NO reply: WebKit hands those to the app synchronously and IN ORDER, which a socket's frames
      // need. Native → page: `deliver(id, [base64…])` per batch, `closed(id)` once. Only "This Mac" is
      // answered (`SocketBridge`).
      const sh = window.webkit.messageHandlers.rdevSocket;
      const sockets = new Map();
      Object.defineProperty(window, "__rdevSocket", {
        value: Object.freeze({
          deliver: (id, frames) => { const s = sockets.get(id); if (s) { try { s.frames(frames); } catch (e) { console.error(e); } } },
          closed: (id) => { const s = sockets.get(id); sockets.delete(id); if (s) { try { s.closed(); } catch (e) { console.error(e); } } },
        }),
      });
      const sourceWindows = new Set();
      Object.defineProperty(window, '__rdevNativeSourceEvent', { value: event => { for (const cb of sourceWindows) { try { cb(event); } catch (e) { console.error(e); } } } });
      const shell = Object.freeze({
        nativeSourceWindowsInfo: () => h.postMessage({op: 'nativeSourceWindowsInfo', args: []}),
        syncSourceWindows: value => h.postMessage({op: 'syncSourceWindows', args: [value]}),
        prepareSourceWindow: (source, generation) => h.postMessage({op: 'prepareSourceWindow', args: [source, generation]}),
        resetSourceWindows: generation => h.postMessage({op: 'resetSourceWindows', args: [generation]}),
        sourceWindowCommand: (key, command, value) => h.postMessage({op: 'sourceWindowCommand', args: [key, command, value ?? null]}),
        onSourceWindowEvent: cb => { sourceWindows.add(cb); return () => sourceWindows.delete(cb); },
        smoothScroll: () => h.postMessage({ op: "smoothScroll", args: [] }),
        setSmoothScroll: (on) => h.postMessage({ op: "setSmoothScroll", args: [on === true] }),
        onSmoothScroll: (cb) => { smooth.add(cb); return () => smooth.delete(cb); },
        sharing: () => h.postMessage({ op: "sharing", args: [] }),
        onSharing: (cb) => { sharing.add(cb); return () => sharing.delete(cb); },
        // The WINDOW's macOS full screen for the page's full-screen window mode (`window-fullscreen.ts`).
        setChromeGap: (left, right, width) => { h.postMessage({ op: "setChromeGap", args: [left, right, width] }).catch(() => {}); },
        setFullscreen: (on) => h.postMessage({ op: "setFullscreen", args: [on === true] }),
        onFullscreenLeft: (cb) => { fsLeft.add(cb); return () => fsLeft.delete(cb); },
        signalingBase: \(json(env.signalingBase)),
        e2eOrigin: \(json(env.e2eOrigin)),
        connectionState: (state, text) => { h.postMessage({ op: "connectionState", args: [state, text] }).catch(() => {}); },
        e2eIdentity: () => h.postMessage({ op: "e2eIdentity", args: [] }),
        issueGrant: (keys) => h.postMessage({ op: "issueGrant", args: [keys] }),
        // The Worker calls `app://client` cannot `fetch` (no CORS for it), performed natively for an
        // allow-list of PATHS on the app's own signalling origin — `WorkerRequest`. Resolves
        // `{status, body, headers}`; a refusal REJECTS. `web/src/lib/worker-fetch.ts` is the caller.
        request: (path, init) => h.postMessage({ op: "request",
          args: [path, (init && init.method) || "GET", init && typeof init.body === "string" ? init.body : null] }),
        socketOpen: (id, handlers) => { sockets.set(id, handlers); sh?.postMessage({ op: "open", id }); },
        socketSend: (id, frame) => { sh?.postMessage({ op: "send", id, frame }); },
        socketClose: (id) => { sockets.delete(id); sh?.postMessage({ op: "close", id }); },
        // WHAT FINDER COPIED (`paste-local.ts`): `[{path, name, dir}]` from the pasteboard; each path made
        // sendable (a folder zipped) as `[{url, name, type, size}]` or a `-`-prefixed refusal; the urls a
        // person decided not to send; and Stop sending while a zip is still being made.
        pasteboardFiles: () => h.postMessage({ op: "pasteboardFiles", args: [] }),
        writeClipboard: text => h.postMessage({ op: "writeClipboard", args: [text] }),
        preparePaste: (paths) => h.postMessage({ op: "preparePaste", args: [paths] }),
        discardPaste: (urls) => h.postMessage({ op: "discardPaste", args: [urls] }),
        cancelPaste: () => h.postMessage({ op: "cancelPaste", args: [] }),
        // THE BELL (`term-bell.ts`): how many of this window's terminal tabs rang a bell nobody has seen —
        // the Dock's badge and the window's title (`BellBadge`).
        setBell: (count) => { h.postMessage({ op: "setBell", args: [count] }).catch(() => {}); },
        // "This Mac"'s Disconnect: the session IS the window, so the window closes (`main.ts`).
        openMacs: () => { h.postMessage({ op: "openMacs", args: [] }).catch(() => {}); },
        activateSimulator: (source) => { h.postMessage({ op: "activateSimulator", args: [source] }).catch(() => {}); },
        simulatorTheme: (theme) => { h.postMessage({ op: "simulatorTheme", args: [theme] }).catch(() => {}); },
        closeWindow: () => { h.postMessage({ op: "closeWindow", args: [] }).catch(() => {}); },
      });
      Object.defineProperty(window, "__rdevShell", { value: shell, enumerable: true });
    })();
    """ }

    static func json(_ value: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }
}
