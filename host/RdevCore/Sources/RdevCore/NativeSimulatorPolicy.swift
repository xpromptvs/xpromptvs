import Foundation

/// Native presentation is granted by the app's authenticated bridge, never by a socket hello.
/// Keep this exhaustive: every new message needs a deliberate native capability decision.
public enum NativeSimulatorPolicy {
    public static func isSimulator(_ source: String?) -> Bool {
        guard let source, case .sim(let udid) = parseSourceID(source) else { return false }
        return UUID(uuidString: udid) != nil
    }

    public static func permits(_ message: InboundMessage, focusedSource: String?) -> Bool {
        switch message {
        case .agent: return true
        case .subscribe(let source, _), .unsubscribe(let source, _), .minimizeWindow(let source, _),
             .restoreWindow(let source), .focusSource(let source), .simAction(let source, _):
            return isSimulator(source)
        case .simTouch, .simText, .winKey, .winKeysRelease, .scroll, .scrollGesture:
            return isSimulator(focusedSource)
        case .setView(_, let fullscreen):
            return fullscreen.flatMap { $0 }.map { isSimulator($0) } ?? true
        case .pasteBegin(let begin):
            switch begin.to {
            case .terminal: return true
            case .window(let source, _):
                return isSimulator(source) && begin.items.allSatisfy { if case .text = $0 { return true }; return false }
            }
        case .moveTab(let tab, let before):
            return permittedTab(tab) && (before.map(permittedTab) ?? true)
        case .renameTab(let tab, _): return permittedTab(tab)
        case .key, .termReply, .claimControl, .resize, .termWire, .terminalPause, .terminalResume,
             .termPalette, .listTerminals, .openTerminal, .reopenTerminal, .closeTerminal, .switchTerminal,
             .listTmux, .openTmux, .newTmux, .killTmux, .clientHello, .setPrefs,
             .pasteData, .pasteEnd, .pasteCancel, .fileGet, .listSources, .requestThumbs:
            return true
        case .sourceInput, .appsCapabilities, .appsList, .appsAdd, .appsRemove, .appsRestoreAll, .av1Reference, .touch, .hover, .scrollFling, .reattachSource, .setWindowPosition, .requestKeyframe,
             .setSourcePrefs, .setSourceSize, .setRecovery, .setPlayoutDelay, .setSourceAudio,
             .setVisibility, .receiverReport, .curtain:
            return false
        }
    }

    private static func permittedTab(_ tab: String) -> Bool {
        TabKey.isAgent(tab) || isSimulator(tab) || tab.hasPrefix("pty:") || tab.hasPrefix("tmux:")
    }
}
