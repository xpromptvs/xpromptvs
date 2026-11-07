import AppKit
import RdevCore
import RdevHostKit
import ShellstormCore

/// A projection of This Mac's admission, never another host client.
@MainActor
final class NativeSimulatorWindows {
    private var session: LocalSimulatorSession?
    private var observation: LocalSimulatorObservation?
    private var binding = UUID()
    private var model = NativeSimulatorWindowsModel()
    private(set) var windows: [String: NativeSimulatorWindow] = [:]
    private var geometry: [String: NSRect] = [:]
    private var last: LocalSimulatorSnapshot?
    private var theme = "dark"
    var onTerminal: (() -> Void)?

    func bind(_ session: LocalSimulatorSession) {
        unbind(); self.session = session
        let token = binding
        observation = session.observeLatest(deliver: { work in
            DispatchQueue.main.async(execute: DispatchWorkItem(block: work))
        }) { [weak self] snapshot in
            MainActor.assumeIsolated {
                guard let self, self.binding == token else { return }
                self.apply(snapshot)
            }
        }
    }
    func unbind() {
        binding = UUID(); observation?.cancel(); observation = nil; session = nil
        for window in windows.values { window.closeForHandoff() }
        windows.removeAll(); model = NativeSimulatorWindowsModel(); last = nil
    }
    private func apply(_ snapshot: LocalSimulatorSnapshot) {
        #if RDEV_DEV_BUILD
        // Negative control for the real app handoff gate; absent from release builds.
        if !snapshot.driving, ProcessInfo.processInfo.environment["RDEV_TEST_NATIVE_KEEP_WINDOWS"] == "1" { return }
        #endif
        if let last, snapshot.generation < last.generation ||
            (snapshot.generation == last.generation && snapshot.revision <= last.revision) { return }
        let previous = last; last = snapshot
        let infos = Dictionary(uniqueKeysWithValues: snapshot.sources.map { ("sim:" + $0.udid, $0) })
        let states = snapshot.state.windows.filter { NativeSimulatorPolicy.isSimulator($0.source) }.map {
            NativeWindowState(source: $0.source, title: $0.name ?? infos[$0.source].map { "\($0.name) · \($0.os)" } ?? "Simulator", minimized: $0.minimized)
        }
        let delta = model.apply(NativeWindowsSnapshot(generation: snapshot.generation, revision: snapshot.revision,
            driving: snapshot.driving, windows: states, focusedSource: snapshot.state.focused,
            terminalActive: snapshot.state.view.surface == .terminal))
        for source in delta.close { windows.removeValue(forKey: source)?.closeForHandoff() }
        guard let session else { return }
        for state in delta.create {
            let epoch = snapshot.generation
            let window = NativeSimulatorWindow(state: state, generation: epoch, frame: geometry[state.source]) { [weak session] message in
                session?.perform(message, source: state.source, generation: epoch)
            }
            window.onGeometry = { [weak self] frame in self?.geometry[state.source] = frame }
            windows[state.source] = window
            window.attach(session)
        }
        for state in states {
            guard let window = windows[state.source] else { continue }
            window.apply(state: state, focused: snapshot.state.focused == state.source, statusText: nil, theme: theme)
            if let info = infos[state.source] { window.setDeviceState(info.state) }
        }
        for state in delta.create { windows[state.source]?.show(focus: false) }
        if let source = delta.front { windows[source]?.show(focus: true) }
        if snapshot.driving, snapshot.state.view.surface == .terminal,
           previous?.state.view.surface == .windows { onTerminal?() }
    }
    func bringForward() {
        guard let session, let snapshot = session.snapshot, snapshot.driving,
              session.current(snapshot.generation) else { return }
        // Reconcile the latest ownership/membership before raising anything; a queued notification may lag.
        apply(snapshot)
        let activation = model.activation()
        for state in activation.update { windows[state.source]?.show(focus: false) }
        if let source = activation.front { windows[source]?.show(focus: true) }
    }

    func activate(source: String) {
        guard let snapshot = session?.snapshot, snapshot.driving, session?.current(snapshot.generation) == true, NativeSimulatorPolicy.isSimulator(source),
              snapshot.state.contains(source) else { return }
        session?.perform(.restoreWindow(source: source), source: source, generation: snapshot.generation)
        session?.perform(.setView(surface: .windows, fullscreen: nil), source: source, generation: snapshot.generation)
        windows[source]?.show(focus: true)
    }
    func setTheme(_ value: String) {
        guard value == "dark" || value == "light" else { return }
        theme = value
        guard let snapshot = last else { return }
        for state in snapshot.state.windows {
            guard let window = windows[state.source] else { continue }
            window.apply(state: NativeWindowState(source: state.source, title: window.window.title, minimized: state.minimized),
                         focused: snapshot.state.focused == state.source, statusText: nil, theme: theme)
        }
    }
}
