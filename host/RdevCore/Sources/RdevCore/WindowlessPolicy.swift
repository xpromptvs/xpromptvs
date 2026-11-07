/// **WHAT A WINDOW-LESS CLIENT MAY SEND** (docs/sources-and-focus.md, "Window-less clients").
///
/// A window-less client is one whose connection carries no media — the app's own Mac, over a socket.
/// It may drive the TERMINAL and take control; it may not touch windows, the picture, input to the
/// Mac's own windows, the page-visibility media pause or the curtain (raised from the Mac's own window
/// it would swallow the keyboard typing into it). The host refuses the rest before any handler runs.
///
/// EXHAUSTIVE, WITH NO `default`: a new `InboundMessage` case does not compile until it is classified
/// here, and its row belongs in `WindowlessPolicyTests` beside it.
public enum WindowlessPolicy {
    public static func permits(_ message: InboundMessage) -> Bool {
        switch message {
        case .agent: return false
        // A paste or drop INTO A WINDOW is a window intent; into a terminal it is not. The rest of a
        // delivery acts only on one a permitted begin opened.
        case .pasteBegin(let b):
            if case .terminal = b.to { return true }
            return false
        case .pasteData, .pasteEnd, .pasteCancel:
            return true
        // An image a terminal printed the path of: the terminal's, and it touches no window.
        case .fileGet:
            return true
        case .key, .termReply, .claimControl, .resize, .termWire, .terminalPause, .terminalResume,
             .termPalette, .listTerminals, .openTerminal, .reopenTerminal, .closeTerminal, .switchTerminal,
             .listTmux, .openTmux, .newTmux, .killTmux, .clientHello, .setPrefs,
             // The BAR's order and its names arrange the session's bar and touch no window of the Mac —
             // and a window-less client shows no window tabs, so it never names one.
             .moveTab, .renameTab:
            return true
        case .sourceInput, .appsCapabilities, .appsList, .appsAdd, .appsRemove, .appsRestoreAll, .av1Reference, .touch, .hover, .scroll, .scrollFling, .scrollGesture, .winKey, .winKeysRelease, .requestThumbs,
             .simTouch, .simText, .simAction,
             .listSources, .subscribe, .unsubscribe, .reattachSource, .minimizeWindow, .restoreWindow,
             .setWindowPosition, .setView, .focusSource, .requestKeyframe, .setSourcePrefs,
             .setSourceSize, .setRecovery, .setPlayoutDelay, .setSourceAudio, .setVisibility,
             .receiverReport, .curtain:
            return false
        }
    }
}
