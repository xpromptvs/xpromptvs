import Foundation

/// Which mouse button a touch message drives.
///
/// The host synthesized LEFT ONLY until this existed. Right-click is a real remote-desktop need — a
/// context menu is unreachable without it — and it costs one optional wire field.
public enum MouseButton: String, Sendable, Equatable {
    case left
    case right

    /// ABSENT MEANS LEFT, and so does anything unrecognised. The same absent-means-default rule
    /// `ScrollUnit.init(wire:)` follows, and for the same reason: a client that predates the field
    /// must be bit-for-bit unchanged, and a version skew must degrade to the ordinary button rather
    /// than refuse the message. A refused touch is a click that silently does nothing.
    public init(wire: String?) {
        self = wire == "right" ? .right : .left
    }
}

public enum MouseEventKind: Sendable, Equatable {
    case down
    case dragged
    case up
}

public struct TouchEventPlan: Sendable, Equatable {
    public let kind: MouseEventKind
    public let button: MouseButton
    public init(kind: MouseEventKind, button: MouseButton) {
        self.kind = kind
        self.button = button
    }
}

/// Map a wire touch phase and button onto the mouse event to post.
///
/// PURE so the six-way mapping is testable without CoreGraphics; the injector does nothing but
/// translate the result into a `CGEventType`.
///
/// AN UNRECOGNISED PHASE IS A DRAG. That is the pre-existing fall-through and it is kept
/// deliberately: the touch phases on the wire are exactly `"down"` and `"up"`, and anything else
/// becoming a drag with no button held registers as NOTHING while the host logs correct
/// coordinates — a trap worth holding in one tested place.
public func touchEventPlan(phase: String, button: MouseButton) -> TouchEventPlan {
    let kind: MouseEventKind = phase == "down" ? .down : (phase == "up" ? .up : .dragged)
    return TouchEventPlan(kind: kind, button: button)
}

/// THE DRIVER'S OWN POINTER STAYS OUT OF A DROP'S CARRY (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md
/// §5). A real drop holds the Mac's left button from its own posted press to its mouse-up — ~0.65 s carrying the
/// REAL cursor to the drop point — and the window server has one cursor and one left button. A tap of the
/// driver's posted meanwhile would end that drag at the TAP's point, possibly in another window: the drop lands
/// where guard 1 never looked. So while a drop carries, the window injector posts NOTHING of the driver's pointer
/// — no touch, no hover, no scroll, no glide's step. Keys are not pointer events and go on.
///
/// DECIDED PER PRESS, AT ITS DOWN: a press whose down was dropped is dropped WHOLE, its drags and its up too, even
/// once the carry has ended — an up for a down nobody posted would reach the app under it as a click it never
/// began. A press that began BEFORE the carry does not exist: the drop's own press is the only one — the drop
/// comes after an upload the browser began only once its own drop had ended every press the page had, and the
/// one driver sends both — so there is no earlier press whose up a carry could strand. Were there one, its up
/// during the carry is dropped like everything else, and the drop's own mouse-up releases the button.
public struct DropCarryGate: Sendable, Equatable {
    /// A press whose down came during a carry: everything until its up is dropped.
    private var swallowing = false

    public init() {}

    /// Whether a touch's mouse event may post, `carrying` read as it is about to.
    public mutating func admits(_ kind: MouseEventKind, carrying: Bool) -> Bool {
        switch kind {
        case .down:
            swallowing = carrying
            return !carrying
        case .dragged:
            return !(carrying || swallowing)
        case .up:
            defer { swallowing = false }
            return !(carrying || swallowing)
        }
    }

    /// A motion with no press — a hover, a scroll, a glide's step: posted only while no drop carries.
    public static func admitsMotion(carrying: Bool) -> Bool { !carrying }
}
