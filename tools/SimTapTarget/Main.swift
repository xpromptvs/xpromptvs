import SwiftUI
import UIKit

// SimTapTarget — the iOS app scripts/gate-simulator.sh taps through rdev
// (docs/superpowers/specs/2026-10-13-simulator-sources-design.md). Four solid quadrants for the eye, and two logs in
// Documents/ that the gate reads:
//
//   gestures.csv  one line per finger lifted: `x,y,w,h,dist` in the view's POINTS, top-left origin — where it lifted,
//                 the view's size AT THAT MOMENT (a tap made after a rotation is checked against the rotated view), and
//                 how far it moved. A TAP is a gesture that barely moved; a wheel's drag must never be one.
//   events.csv    one line per lifecycle change: `resign` (Home sent it to the background) and `active`.
//
// The logs are APPENDED and never cleared: the gate's device is new, and a relaunch after a reboot must not wipe what
// the arms before it recorded.
@main
struct SimTapTargetApp: App {
    static let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let gestures = docs.appendingPathComponent("gestures.csv")
    static let events = docs.appendingPathComponent("events.csv")

    var body: some Scene {
        WindowGroup { ContentView() }
    }

    static func append(_ line: String, to url: URL) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

struct ContentView: View {
    @State private var text = ""
    @FocusState private var editing: Bool
    private let nativeProbe = ProcessInfo.processInfo.arguments.contains("--native-probe")
    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 0) { Color.red; Color.green }
                HStack(spacing: 0) { Color.blue; Color.yellow }
            }
            .overlay {
                if nativeProbe {
                    ZStack {
                        TextField("Native input probe", text: $text)
                            .autocorrectionDisabled(true).textInputAutocapitalization(.never)
                            .focused($editing)
                            .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidChangeNotification)) { event in
                                if let field = event.object as? UITextField {
                                    SimTapTargetApp.append(field.text ?? "", to: SimTapTargetApp.docs.appendingPathComponent("uikit-text.txt"))
                                }
                            }
                            .onChange(of: editing) { _, value in
                                try? (value ? "yes" : "no").write(to: SimTapTargetApp.docs.appendingPathComponent("focus.txt"), atomically: true, encoding: .utf8)
                            }
                            .textFieldStyle(.roundedBorder).frame(width: proxy.size.width - 48, height: 40)
                            .position(x: proxy.size.width / 2, y: proxy.size.height * 0.15)
                            .onChange(of: text) { _, value in
                                SimTapTargetApp.append(value, to: SimTapTargetApp.docs.appendingPathComponent("text.txt"))
                            }
                        // A four-bit frame identifier repeated across distant rows catches a tear
                        // between rows as well as within one scanline. One TimelineView stamps all rows.
                        TimelineView(.animation(minimumInterval: 1.0 / 60)) { tick in
                            let frame = Int(tick.date.timeIntervalSinceReferenceDate * 60) % 16
                            ZStack {
                                ForEach([0.32, 0.50, 0.68, 0.86], id: \.self) { y in
                                    HStack(spacing: 0) {
                                        ForEach(0..<4) { bit in
                                            Rectangle().fill(frame & (1 << bit) != 0 ? Color.white : Color.black)
                                        }
                                    }.frame(width: proxy.size.width, height: 24)
                                     .position(x: proxy.size.width / 2, y: proxy.size.height * y)
                                }
                            }
                        }.allowsHitTesting(false)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                let p = value.location, s = proxy.size
                let dist = Int(hypot(value.translation.width, value.translation.height).rounded())
                SimTapTargetApp.append("\(Int(p.x)),\(Int(p.y)),\(Int(s.width)),\(Int(s.height)),\(dist)",
                                       to: SimTapTargetApp.gestures)
            })
        }
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            try? "shown".write(to: SimTapTargetApp.docs.appendingPathComponent("keyboard.txt"), atomically: true, encoding: .utf8)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            try? "hidden".write(to: SimTapTargetApp.docs.appendingPathComponent("keyboard.txt"), atomically: true, encoding: .utf8)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            SimTapTargetApp.append("resign", to: SimTapTargetApp.events)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            SimTapTargetApp.append("active", to: SimTapTargetApp.events)
        }
    }
}
