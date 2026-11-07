import Foundation

/// One query-like sequence a scan saw COMPLETE: `end` is the offset just past it in the scanned bytes,
/// `clientReplies` how many answers the client's xterm.js gives it (0: the host's to answer).
/// `queryLike`: it is in one of the measured sets (what xterm.js or SwiftTerm answers as a query) —
/// the only kind the host ever types an answer for; the rest are hits only so the send buffer never
/// holds them. `start`: where the sequence BEGAN, as an offset into the WHOLE stream the scanner has
/// been fed (`StreamingQueryStripper.fed`) — so a query begun in an earlier call, before a snapshot the
/// caller took in between, can be told apart from one begun after it.
/// `query`: the whole sequence, for one xterm.js answers — what the host answers AS xterm.js would
/// (`TermHostReplies`) — or nil (xterm.js answers nothing). For a COLOUR query longer than the hold,
/// whose bytes are gone, it is an EQUIVALENT short query rebuilt from the shape kept while it streamed
/// (`StringBody.equivalentQuery`): `TermHostReplies` answers it exactly as xterm.js answers the long one
/// (up to `StringBody.maxReports` answers). A long DCS has none. `osc`: an OSC introduced it (7-bit or
/// C1) — for a query-like hit, a COLOUR query.
public struct TermQueryHit: Equatable, Sendable {
    public let end: Int
    public let clientReplies: Int
    public let queryLike: Bool
    public let start: Int
    public let query: [UInt8]?
    public let osc: Bool
    public init(end: Int, clientReplies: Int, queryLike: Bool = true, start: Int = 0, query: [UInt8]? = nil,
                osc: Bool = false) {
        self.end = end; self.clientReplies = clientReplies; self.queryLike = queryLike; self.start = start
        self.query = query; self.osc = osc
    }
}

/// The device queries in a terminal byte stream, found as the CLIENT's xterm.js 6 parses it
/// (docs/terminal.md, "Who answers a device query"). Two roles; an instance is used for one, never both.
///
/// A STRIPPER for a tmux tab's live stream (`feed`). tmux answers device queries itself (it is the
/// pane's terminal), so a query left in the stream would be answered AGAIN by xterm.js and typed into
/// the pane — but only the ones tmux answers (measured, `tmuxAnswers`): a query xterm.js answers and tmux
/// does not (OSC 4, OSC 12, DECDSR) is left in, or nobody would answer it. A sequence split across two
/// chunks is held back until it completes; one longer than
/// `maxHold` is released as it comes — and a long OSC/DCS QUERY among them is ended by CAN in place of
/// its terminator, so xterm.js aborts it instead of answering it a second time. tmux reads BYTES and
/// answers no query an 8-bit C1 code point introduces or ends (measured): those are left in, for
/// xterm.js to answer, once.
///
/// A SCANNER for a `pty:` tab (`scan`): every sequence that COULD be a query and that these bytes
/// complete, and how many answers the client's xterm.js gives it — EXACTLY the answers xterm.js 6
/// gives as the product configures it, measured against a real instance
/// (`protocol/fixtures/term-client-queries.json`, `TermClientQueriesFixtureTests`). "Could be a query"
/// is wider than either emulator's set, because the send buffer never holds one: every sequence
/// xterm.js 6 has a handler that can answer (walked from its registered handlers,
/// `term-reply-handlers.json`, `TermReplyHandlersFixtureTests`), any DCS, any OSC that asks with `?`.
///
/// It reads the stream as xterm.js does: as the CODE POINTS a UTF-8 decoder yields, so U+009B, U+009D,
/// U+0090 and U+009C (bytes C2 9B, C2 9D, C2 90, C2 9C) are CSI, OSC, DCS and ST in every state and
/// any other C1 code point aborts a sequence (`EscapeSequenceParser`'s "anywhere" rules). An OSC or
/// DCS longer than `maxHold` keeps its CLASSIFICATION across reads without keeping its bytes, so it is
/// still found — once — on the read that ends it.
public struct StreamingQueryStripper: Sendable {
    /// An unfinished sequence, held for the next call (at most `maxHold` bytes), or the one lead byte
    /// of a code point that may be a C1 terminator of a `long` string.
    private var held: [UInt8] = []
    /// An OSC/DCS whose bytes outgrew `maxHold` and were released, and which has not ended yet.
    private var long: StringBody?
    /// Where `long` began, as a stream offset (`fed`).
    private var longStart = 0
    /// Bytes fed so far, over every call: the stream offset of the next byte.
    public private(set) var fed = 0
    private let maxHold = 4096
    /// A LEFT-IN query (tmux path) whose terminator is the ESC at `held[0]` — the ESC that ends an OSC
    /// or DCS for xterm.js and begins the next sequence, held because that sequence is not finished.
    /// Its body went out, its terminator did not: xterm.js has not answered it, so it is neither the
    /// client's nor the host's yet. It is decided by the run that RELEASES that ESC (into `left`, with
    /// the credit when the bytes are forwarded), or handed over by `takePending` when the stripper is
    /// discarded with the ESC still held — the client's instance then never sees the terminator, and
    /// the host answers. Until 2026-09-27 such a query counted as reached at once, and a pause, a pane
    /// change or a snapshot after it left it answered by NOBODY (docs/terminal.md, L1).
    private var pending: (replies: Int, query: [UInt8]?)?
    /// `held[0]` is an ESC that ENDED or ABORTED the sequence before it (a string's terminator, a CSI
    /// restarted). If the sequence it begins is a query the stripper removes, the ESC is kept (as
    /// `ESC \`), or the client would never see the end of what came before it (`strip`).
    private var heldInterrupts = false

    public init() {}

    /// The left-in query still waiting for its terminator (see `pending`), whole, for the HOST to answer
    /// — called when the stripper is about to be discarded (a snapshot, a `%pause`): the ESC it holds
    /// is never forwarded to the instance that saw the query's body.
    public mutating func takePending() -> [[UInt8]] {
        defer { pending = nil }
        guard let p = pending, p.replies > 0, let q = p.query else { return [] }
        return [q]
    }

    /// `bytes` with every query-like sequence removed (tmux tabs).
    public mutating func feed(_ bytes: [UInt8]) -> [UInt8] { run(bytes, output: true).out }

    /// `feed`, and what the queries LEFT IN the output ask of the client's xterm.js: how many answers it
    /// gives them (`clientReplies` — the tmux tab owes the client that many `term-reply`s: tmux does not
    /// answer these), and whether any sequence that could be a query was left in at all (`mayAsk` — the
    /// tmux send path never holds one). A query neutralised with CAN is not left in. `left`: each left-in
    /// query xterm.js answers, whole, in order — what the HOST answers (`TermHostReplies`) when these
    /// bytes reach no client. A colour query longer than the hold, whose bytes are gone, is returned as
    /// its equivalent short query (`StringBody.equivalentQuery`). A query whose terminating ESC is still
    /// held is in neither count nor `left` until a later call releases that ESC (`pending`).
    public mutating func feedCounting(_ bytes: [UInt8]) -> (out: [UInt8], clientReplies: Int, mayAsk: Bool, left: [[UInt8]]) {
        let r = run(bytes, output: true)
        return (r.out, r.leftReplies, r.leftUrgent, r.left.map(\.query))
    }

    /// `feedCounting`, with each left-in query's END as an offset into `bytes` (clamped to `0...count`):
    /// where the pane's stream stood when xterm.js would have answered it — the host answers a C1 DECRQM
    /// from the modes AS OF that point, not after the whole read (`TermModeTracker.modes(feeding:at:)`).
    public mutating func feedLocating(_ bytes: [UInt8]) -> (out: [UInt8], clientReplies: Int, mayAsk: Bool, left: [(query: [UInt8], end: Int)]) {
        let r = run(bytes, output: true)
        return (r.out, r.leftReplies, r.leftUrgent, r.left)
    }

    /// Every query-like sequence these bytes COMPLETE, in order — one begun in an earlier call included,
    /// counted on the call that completes it, its `end` an offset into THESE bytes: just past the code
    /// point at which xterm.js acts on it (a CSI's final; an OSC/DCS's BEL, ST, CAN/SUB, the C1 code
    /// point that drops it, or the ESC ending it — known at that ESC, with no lookahead).
    public mutating func scan(_ bytes: [UInt8]) -> [TermQueryHit] { run(bytes, output: false).hits }

    /// Bytes a stripper's caller will NOT forward (a withheld tmux pane): followed like `feed`, so a query
    /// they complete is found once, and returned as `feedCounting`'s `left` — nothing is output.
    /// The output is never built (`output: false`): nothing in `run` that decides `left` or the state
    /// it carries reads it (`TermQueryC1AndLongTests.testWithholdClassifiesExactlyAsFeedCounting`).
    public mutating func withhold(_ bytes: [UInt8]) -> [[UInt8]] { run(bytes, output: false).left.map(\.query) }

    /// `withhold`, with each query's end in `bytes` (as `feedLocating`).
    public mutating func withholdLocating(_ bytes: [UInt8]) -> [(query: [UInt8], end: Int)] { run(bytes, output: false).left }

    /// Whether these bytes complete a query-like sequence (the send buffer never holds one).
    public mutating func detectsQuery(_ bytes: [UInt8]) -> Bool { !scan(bytes).isEmpty }

    /// How many answers the client's xterm.js gives to the queries these bytes complete.
    public mutating func countQueries(_ bytes: [UInt8]) -> Int { scan(bytes).map(\.clientReplies).reduce(0, +) }

    private static let CAN: UInt8 = 0x18

    private mutating func run(_ bytes: [UInt8], output: Bool)
        -> (hits: [TermQueryHit], out: [UInt8], leftReplies: Int, leftUrgent: Bool, left: [(query: [UInt8], end: Int)]) {
        var hits: [TermQueryHit] = []
        var left: [(query: [UInt8], end: Int)] = []
        let clamp = { (i: Int) in min(max(i, 0), bytes.count) }
        var out: [UInt8] = []
        var leftReplies = 0, leftUrgent = false
        var rest = bytes
        var base = 0                                   // where `rest` starts in `bytes` (-1: a held lead byte)
        let fedBefore = fed
        fed += bytes.count
        // A left-in query whose terminating ESC is at `buf[0]` below (held from the last call, or ending
        // the long string just now): decided once `released` is known.
        var waiting = pending
        pending = nil
        var interruptsAtStart = heldInterrupts
        heldInterrupts = false
        if var body = long {
            let input = held + bytes
            let pre = held.count
            held = []
            switch Self.stringEnd(input, from: 0, body: &body) {
            case .open(let lead):
                let keep = lead ?? input.count
                if output { out = Array(input[..<keep]) }
                held = Array(input[keep...])
                long = body
                pending = waiting
                return (hits, out, 0, false, [])
            case .broken(let at):
                long = nil
                if output { out = Array(input[..<at]) }
                rest = Array(input[at...]); base = at - pre
            case .ended(let e):
                long = nil
                let replies = body.replies(success: e.success)
                let query = (replies ?? 0) > 0 ? body.equivalentQuery() : nil
                if body.urgent(replies) {
                    hits.append(TermQueryHit(end: e.feedEnd - pre, clientReplies: replies ?? 0, queryLike: replies != nil, start: longStart,
                                             query: query, osc: !body.dcs))
                }
                // tmux answers this query (7-bit, whole): a CAN ends it for xterm.js instead, which
                // aborts it. A BEL is replaced (it would ring after the CAN); an ESC stays, it begins
                // the next sequence.
                let canned = replies != nil && e.success && !body.c1 && !e.c1 && body.tmuxAnswers
                if output {
                    out = canned ? Array(input[..<e.term]) + [Self.CAN] + (input[e.term] == 0x07 ? [] : Array(input[e.term..<e.next]))
                                 : Array(input[..<e.next])
                }
                if !canned, body.urgent(replies) {
                    leftUrgent = true
                    // Ended by a bare ESC: that ESC begins what follows, at `buf[0]`.
                    if e.next == e.term && input[e.term] == 0x1b { waiting = (replies ?? 0, query); interruptsAtStart = true }
                    else { leftReplies += replies ?? 0; if let query, (replies ?? 0) > 0 { left.append((query, clamp(e.feedEnd - pre))) } }
                } else if !canned && e.next == e.term && input[e.term] == 0x1b {
                    interruptsAtStart = true                           // it ends a string xterm.js still has open
                }
                rest = Array(input[e.next...]); base = e.next - pre
            }
        }
        let before = held.count
        let buf = held + rest
        held = []
        // The stream offset of `buf[k]` is `origin + k`: `held` is always the stream's last bytes.
        let origin = fedBefore + base - before
        var released = buf.count
        let (found, interruptions) = Self.walkPoints(buf, interruptsAtStart: interruptsAtStart)
        if let cut = Self.incompleteTail(buf) {
            if buf.count - cut <= maxHold {
                held = Array(buf[cut...]); released = cut
                heldInterrupts = interruptions.contains(cut)
            } else if let open = Self.openString(buf, at: cut) {
                long = open.0
                longStart = origin + cut
                if let lead = open.1 { held = [0xC2]; released = lead }
            }
        }
        // The waiting query's ESC is `buf[0]`: released now (forwarded, or withheld — either way the
        // caller decides it with this call's `left`), or still held.
        if let w = waiting {
            if released > 0 {
                leftUrgent = true; leftReplies += w.replies
                if w.replies > 0, let q = w.query { left.append((q, clamp(base - before + 1))) }
            } else {
                pending = w
            }
        }
        for f in found where f.feedEnd > before {
            let query = (f.replies ?? 0) > 0 ? Array(buf[f.start..<f.feedEnd]) : nil
            hits.append(TermQueryHit(end: f.feedEnd - before + base, clientReplies: f.replies ?? 0, queryLike: f.replies != nil,
                                     start: origin + f.start, query: query, osc: Self.isOSC(buf, at: f.start)))
            if !f.strip && f.start < released {
                leftUrgent = true
                // Its terminator is the held ESC (`feedEnd` is just past it): not sent yet.
                if f.feedEnd > released { pending = (f.replies ?? 0, query); continue }
                leftReplies += f.replies ?? 0
                if let query { left.append((query, clamp(f.feedEnd - before + base))) }
            }
        }
        if output { out += Self.strip(buf, upTo: released, found: found, interruptions: interruptions) }
        return (hits, out, leftReplies, leftUrgent, left)
    }

    /// Index of a trailing sequence that has not finished, or nil. Found by a FORWARD walk: the last ESC
    /// is not enough — the ESC of an OSC/DCS's own ST (`ESC \`) arriving alone would read as the start of
    /// a new sequence, releasing the open string ahead of it as if it were complete.
    ///
    /// `ESC` + intermediates (0x20-0x2F) with no final yet (`ESC (` of `ESC ( 0`, `ESC # 8`) is
    /// unfinished too: cut there, its start used to be treated as complete and the orphan final painted
    /// as text. So is a trailing C2, which may begin a C1 code point. `PaneStreamCarry` uses this same
    /// function, so the two never disagree.
    static func incompleteTail(_ b: [UInt8]) -> Int? {
        var i = 0
        while i < b.count {
            switch introducer(b, at: i) {
            case .none(let n): i = n
            case .incomplete: return i
            case .sequence:
                switch step(b, at: i) {
                case .incomplete: return i
                case .next(let n), .restart(let n), .seq(_, _, let n, _, _, _, _, _): i = n
                }
            }
        }
        return nil
    }

    /// Remove the device QUERIES from a live stream.
    ///
    /// tmux answers every query itself (it is the pane's terminal), so a query left in the stream would
    /// be answered AGAIN by xterm.js and typed into the pane as INPUT. Stripping is visually a no-op — a
    /// query paints nothing. It removes every QUERY-LIKE sequence (`walk`) that a 7-bit introducer
    /// begins and a 7-bit terminator ends, except those xterm.js answers and tmux does not. Deliberately NOT all of
    /// DCS — a stream can legitimately carry sixel image data — and nothing C1 touches: tmux answers none.
    static func strip(_ bytes: [UInt8]) -> [UInt8] {
        let (found, interruptions) = walkPoints(bytes, interruptsAtStart: false)
        return strip(bytes, upTo: bytes.count, found: found, interruptions: interruptions)
    }

    /// `bytes[..<upTo]` minus every strippable query in it (a query whose ending ESC is the first held
    /// byte is removed up to it; that ESC belongs to the next sequence).
    ///
    /// A stripped query whose ESC ENDS or ABORTS the sequence before it (`interruptions` — an OSC/DCS
    /// ended by that ESC, a CSI it restarts) leaves `ESC \` in its place: the ESC is what tells xterm.js
    /// the earlier sequence is over, and the `\` makes it a no-op of its own. Removed with the query, the
    /// earlier sequence ran on into whatever followed — `OSC 4;1;? ESC [ c text` reached xterm.js as a
    /// colour query whose last slot was `?text`, answered by nobody (and a title swallowed the text).
    static func strip(_ bytes: [UInt8], upTo released: Int, found: [Found], interruptions: Set<Int>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(released)
        var i = 0
        for q in found where q.strip && q.start < released && q.start >= i {
            out.append(contentsOf: bytes[i..<q.start])
            let end = min(q.stripEnd, released)
            if interruptions.contains(q.start) { out += [0x1b, 0x5c] }
            // A C0 byte the parser EXECUTES in place (a CR in the ESC state or in a CSI) is not part of
            // the query: it stays. Inside an OSC/DCS a C0 byte is ignored, so it goes with the string.
            out.append(contentsOf: q.keep)
            i = end
        }
        if i < released { out.append(contentsOf: bytes[i..<released]) }
        return out
    }

    /// `replies`: the answers xterm.js gives (nil: not query-like — neither emulator's set). `strip`:
    /// the tmux stripper removes it (query-like, and no C1 code point introduced or ended it).
    typealias Found = (start: Int, stripEnd: Int, feedEnd: Int, replies: Int?, strip: Bool, keep: [UInt8])

    /// Every sequence in `bytes` that could be a query and whose ENDING code point is in it. Query-LIKE
    /// (`replies` not nil) is everything either side answers — CSI `c` and `n` (DA, DSR), `… $ p`
    /// (DECRQM), the reply-producing window ops `t`, `? u` (kitty keyboard), `> q` (XTVERSION), `… * y`
    /// (DECRQCRA); OSC 4/10/11/12 carrying a `?`; DCS `$ q` (DECRQSS) and `+ q` (XTGETTCAP) — so
    /// SwiftTerm's answers can be attributed per query. Beyond it, every sequence that could still ask
    /// (`replies` nil): any CSI whose final is one xterm.js answers (c, n, t, `$ p`), any DCS, any OSC
    /// with a `?` slot or ending in `?`. `stripEnd`: what a strip removes (an ST included; an ending
    /// ESC that begins the next sequence not). `feedEnd`: just past the code point the parser acts on.
    static func walk(_ bytes: [UInt8]) -> [Found] { walkPoints(bytes, interruptsAtStart: false).found }

    /// `walk`, and every index where an ESC ENDS or ABORTS the sequence before it and begins the next
    /// (an OSC/DCS ended by a bare ESC, a CSI or an ESC sequence restarted) — `interruptsAtStart`: index
    /// 0 is such an ESC (it ended something in an earlier call).
    static func walkPoints(_ bytes: [UInt8], interruptsAtStart: Bool) -> (found: [Found], interruptions: Set<Int>) {
        var found: [Found] = []
        var interruptions: Set<Int> = interruptsAtStart ? [0] : []
        var i = 0
        while i < bytes.count {
            switch introducer(bytes, at: i) {
            case .none(let n): i = n
            case .incomplete: return (found, interruptions)
            case .sequence:
                switch step(bytes, at: i) {
                case .incomplete: return (found, interruptions)
                case .next(let n): i = n
                case .restart(let n): interruptions.insert(n); i = n
                case .seq(let stripEnd, let feedEnd, let n, let replies, let urgent, let c1, let tmux, let keep):
                    if urgent { found.append((i, stripEnd, feedEnd, replies, replies != nil && !c1 && tmux, keep)) }
                    // A string ended by a bare ESC: that ESC begins the next sequence.
                    if feedEnd > n, n < bytes.count, bytes[n] == 0x1b { interruptions.insert(n) }
                    i = n
                }
            }
        }
        return (found, interruptions)
    }

    /// Whether the sequence `walk` found at `i` is an OSC: C1 OSC, or an ESC whose kind byte — past the C0
    /// and DEL the ESC state executes or ignores — is `]`.
    static func isOSC(_ b: [UInt8], at i: Int) -> Bool {
        if b[i] == 0xC2 { return i + 1 < b.count && b[i + 1] == 0x9d }
        var j = i + 1
        while j < b.count, isExecuted(b[j]) || b[j] == 0x7f { j += 1 }
        return j < b.count && b[j] == 0x5d
    }

    enum Introducer { case none(Int), incomplete, sequence }

    /// What begins at `i` in the GROUND state: an ESC, a C1 CSI/OSC/DCS (C2 9B / C2 9D / C2 90) — or
    /// nothing, and where to look next. Any other C1 code point is skipped whole (in the ground state
    /// it executes or ignores; SOS/PM/APC strings hold no query that the same rules do not end).
    static func introducer(_ b: [UInt8], at i: Int) -> Introducer {
        switch b[i] {
        case 0x1b: return i + 1 < b.count ? .sequence : .incomplete
        case 0xC2:
            guard i + 1 < b.count else { return .incomplete }
            let n = b[i + 1]
            if n == 0x9b || n == 0x9d || n == 0x90 { return .sequence }
            return .none((0x80...0x9f).contains(n) ? i + 2 : i + 1)
        default: return .none(i + 1)
        }
    }

    enum Step {
        /// Not finished within these bytes.
        case incomplete
        /// Nothing query-like here (or an aborted sequence): continue at `n`.
        case next(Int)
        /// Nothing query-like here: an ESC at `n` ended or aborted it and begins the next sequence.
        case restart(Int)
        /// A finished sequence. `replies` nil unless it is query-like; `urgent` if it could be a query
        /// at all; `c1` if a C1 code point introduced or ended it; `tmux` unless it is one xterm.js
        /// answers and tmux 3.7c does NOT (measured: OSC 4, OSC 12, OSC 10/11 asking more than one
        /// colour, DECDSR). Continue at `next`. `keep`: the C0 bytes inside it that the parser executes
        /// in place (a strip keeps them).
        case seq(stripEnd: Int, feedEnd: Int, next: Int, replies: Int?, urgent: Bool, c1: Bool, tmux: Bool, keep: [UInt8])
    }

    /// C0 bytes a parser EXECUTES (or ignores) in place inside an escape or control sequence — every C0
    /// but the ones that end or restart one (CAN, SUB, ESC). `BEL` is among them except where it ends an
    /// OSC.
    static func isExecuted(_ c: UInt8) -> Bool { c < 0x20 && c != 0x18 && c != 0x1a && c != 0x1b }

    /// One sequence starting at the ESC or C1 introducer at `i` (`introducer` said `.sequence`), parsed
    /// as xterm.js 6 parses it (`EscapeSequenceParser.ts`): in the ESC state and in a CSI, a C0 byte is
    /// EXECUTED in place — never a final byte or a parameter — and DEL is ignored; an ESC anywhere
    /// RESTARTS a sequence; CAN/SUB abort; a C1 code point acts wherever it appears. A CSI follows the
    /// table's states (a private marker only first, a late one makes it IGNORED) and is aborted by a
    /// non-ASCII code point. An OSC ends at BEL, an OSC or DCS at ST (7-bit or C1), at CAN/SUB (an
    /// abort: no answer), at any other C1 code point (dropped: no answer), or at ANY ESC — which xterm.js
    /// acts on right there and which then begins the next sequence (an ST's `\` is a no-op sequence of
    /// its own). Inside a DCS a BEL is data. C0 is dropped from an OSC body and a DCS header, as the
    /// parser drops it.
    static func step(_ b: [UInt8], at i: Int) -> Step {
        var j: Int
        let kind: UInt8
        let c1 = b[i] == 0xC2
        var executedBefore: [UInt8] = []
        if c1 {
            kind = b[i + 1] == 0x9b ? 0x5b : b[i + 1] == 0x9d ? 0x5d : 0x50
            j = i + 2
        } else {
            j = i + 1
            var inter = false
            while j < b.count {                                        // the ESC state
                let c = b[j]
                if isExecuted(c) || c == 0x7f { j += 1; continue }
                if c == 0x1b { return .restart(j) }                    // restart
                if c == 0x18 || c == 0x1a { return .next(j + 1) }      // abort
                if (0x20...0x2f).contains(c) { inter = true; j += 1; continue }
                // A byte >= 0x80 is an error (back to ground) or a C1 code point: the walker reads it.
                if inter || !(c == 0x5b || c == 0x5d || c == 0x50) { return .next(c >= 0x80 ? j : j + 1) }
                break
            }
            guard j < b.count else { return .incomplete }
            executedBefore = b[(i + 1)..<j].filter(isExecuted)
            kind = b[j]
            j += 1
        }
        if kind == 0x5b { return csi(b, from: j, keep: executedBefore, c1: c1) }
        var body = StringBody(dcs: kind == 0x50, c1: c1)
        switch stringEnd(b, from: j, body: &body) {
        case .open: return .incomplete
        case .broken(let at): return .next(at)
        case .ended(let e):
            let replies = body.replies(success: e.success)
            return .seq(stripEnd: e.stripEnd, feedEnd: e.feedEnd, next: e.next, replies: replies,
                        urgent: body.urgent(replies), c1: c1 || e.c1, tmux: body.tmuxAnswers, keep: executedBefore)
        }
    }

    /// A CSI's body from `j`, through xterm.js 6's CSI_ENTRY / CSI_PARAM / CSI_INTERMEDIATE /
    /// CSI_IGNORE states: a private marker (`<=>?`) only as the first byte, parameters 0x30-0x3B, then
    /// intermediates; a marker after a parameter, or a parameter after an intermediate, makes the CSI
    /// IGNORED — its final dispatches nothing (`CSI 6 ? n` is not a DSR). The first parameter is
    /// clamped as xterm.js clamps it (`CSI 99999999999999999999 c` is not a DA1).
    static func csi(_ b: [UInt8], from j: Int, keep before: [UInt8], c1: Bool) -> Step {
        var k = j
        var state = 0                      // 0 entry, 1 param, 2 intermediate, 3 ignore
        var prefix: UInt8?
        var first = 0, firstDone = false
        var inter: [UInt8] = []
        var keep = before
        while k < b.count {
            let c = b[k]
            if c == 0x1b { return .restart(k) }
            if c == 0x18 || c == 0x1a { return .next(k + 1) }
            if c >= 0x80 {
                guard state == 3 else { return .next(k) }              // aborted; the code point is text or a C1
                if c == 0xC2 {                                         // a C1 code point acts even here
                    guard k + 1 < b.count else { return .incomplete }
                    if (0x80...0x9f).contains(b[k + 1]) { return .next(k) }
                }
                k += 1; continue                                       // ignored
            }
            if isExecuted(c) { keep.append(c); k += 1; continue }
            if c == 0x7f { k += 1; continue }
            if (0x40...0x7e).contains(c) {
                if state == 3 { return .next(k + 1) }
                let q = CSIQuery(prefix: prefix, first: first, inter: inter, final: c)
                let replies = q.isQueryLike ? q.xtermReplies : nil
                return .seq(stripEnd: k + 1, feedEnd: k + 1, next: k + 1, replies: replies,
                            urgent: replies != nil || q.mayAsk, c1: c1, tmux: q.tmuxAnswers, keep: keep)
            }
            switch (state, c) {
            case (0, 0x3c...0x3f): prefix = c; state = 1
            case (0...1, 0x30...0x3b):
                state = 1
                if !firstDone {
                    if c == 0x3b || c == 0x3a { firstDone = true } else { first = min(first * 10 + Int(c - 0x30), 0x7fff_ffff) }
                }
            case (1, 0x3c...0x3f), (2, 0x30...0x3f): state = 3
            case (0...2, 0x20...0x2f): if inter.count < 3 { inter.append(c) }; state = 2
            default: break                                             // CSI_IGNORE takes 0x20-0x3F
            }
            k += 1
        }
        return .incomplete
    }

    /// A dispatched CSI's identity, as xterm.js looks its handler up (prefix, intermediates, final) plus
    /// the first parameter.
    struct CSIQuery {
        let prefix: UInt8?, first: Int, inter: [UInt8], final: UInt8

        /// Something either side may answer (the stripper's and SwiftTerm's attribution set).
        var isQueryLike: Bool {
            switch final {
            case 0x63, 0x6e: return true                                        // 'c' DA, 'n' DSR
            case 0x70: return inter == [0x24]                                   // '$' 'p' — DECRQM
            case 0x74: return [11, 13, 14, 15, 16, 18, 19, 20, 21].contains(first)   // window ops that reply
            case 0x75: return prefix == 0x3f                                    // '? u' — kitty keyboard
            case 0x71: return prefix == 0x3e && inter.isEmpty                   // '> q' — XTVERSION
            case 0x79: return inter == [0x2a]                                   // '* y' — DECRQCRA
            default: return false
            }
        }

        /// Every CSI a handler xterm.js 6 registers could answer, whatever its parameters
        /// (`term-reply-handlers.json`: c, > c, n, ? n, $ p, ? $ p, t) — by FINAL, so a marker or
        /// intermediate xterm.js may register later is covered too.
        var mayAsk: Bool { [0x63, 0x6e, 0x74].contains(final) || final == 0x70 && inter.contains(0x24) }

        /// False for the one CSI xterm.js answers that tmux 3.7c does not: DECDSR `CSI ? 6 n` (measured —
        /// DA1, DA2, DSR 5/6 and every DECRQM tmux answers itself).
        var tmuxAnswers: Bool { !(final == 0x6e && prefix == 0x3f) }

        /// The answers xterm.js 6 gives (InputHandler: DA1/DA2 only for a 0 or absent parameter, DSR 5
        /// and 6, DECDSR ?6, DECRQM always; no window op, since the product enables no `windowOptions`).
        var xtermReplies: Int {
            switch (final, prefix, inter) {
            case (0x63, nil, []), (0x63, 0x3e, []): return first == 0 ? 1 : 0
            case (0x6e, nil, []): return first == 5 || first == 6 ? 1 : 0
            case (0x6e, 0x3f, []): return first == 6 ? 1 : 0
            case (0x70, nil, [0x24]), (0x70, 0x3f, [0x24]): return 1
            default: return 0
            }
        }
    }

    /// Where an OSC/DCS body starting at `j` ends. `term` is the terminator's index; `next` where the
    /// walk resumes (at an ending ESC or C1 introducer, which begins the next sequence).
    struct Ended { let feedEnd: Int, stripEnd: Int, next: Int, term: Int, success: Bool, c1: Bool }
    enum StringEnd {
        /// Every byte consumed; `lead`: a trailing C2 NOT consumed — it may be a C1 code point.
        case open(lead: Int?)
        /// A DCS header met a non-ASCII code point: xterm.js is back in the ground state at `at`.
        case broken(Int)
        case ended(Ended)
    }

    static func stringEnd(_ b: [UInt8], from j: Int, body: inout StringBody) -> StringEnd {
        var k = j
        while k < b.count {
            let c = b[k]
            if c == 0xC2 {
                guard k + 1 < b.count else { return .open(lead: k) }
                let n = b[k + 1]
                if n == 0x9c { return .ended(Ended(feedEnd: k + 2, stripEnd: k + 2, next: k + 2, term: k, success: true, c1: true)) }
                // Any other C1 code point drops the string — xterm.js never ends it, so nothing answers —
                // and the walk resumes AT it: an introducer begins the next sequence.
                if (0x80...0x9f).contains(n) { return .ended(Ended(feedEnd: k + 2, stripEnd: k, next: k, term: k, success: false, c1: true)) }
            }
            if c == 0x1b {
                let st = k + 1 < b.count && b[k + 1] == 0x5c
                return .ended(Ended(feedEnd: k + 1, stripEnd: st ? k + 2 : k, next: st ? k + 2 : k, term: k, success: true, c1: false))
            }
            if c == 0x07 && !body.dcs || c == 0x18 || c == 0x1a {
                return .ended(Ended(feedEnd: k + 1, stripEnd: k + 1, next: k + 1, term: k, success: c == 0x07, c1: false))
            }
            if !body.put(c) { return .broken(k) }
            k += 1
        }
        return .open(lead: nil)
    }

    /// The OSC/DCS that begins at `i` and does not end within `b` — its classification so far, and a
    /// trailing lead byte it did not consume — or nil if what begins there is not a string.
    static func openString(_ b: [UInt8], at i: Int) -> (StringBody, Int?)? {
        let j: Int, dcs: Bool, c1: Bool
        if b[i] == 0xC2 {
            guard i + 1 < b.count, b[i + 1] == 0x9d || b[i + 1] == 0x90 else { return nil }
            dcs = b[i + 1] == 0x90; c1 = true; j = i + 2
        } else {
            var k = i + 1
            while k < b.count, isExecuted(b[k]) || b[k] == 0x7f { k += 1 }
            guard k < b.count, b[k] == 0x5d || b[k] == 0x50 else { return nil }
            dcs = b[k] == 0x50; c1 = false; j = k + 1
        }
        var body = StringBody(dcs: dcs, c1: c1)
        guard case .open(let lead) = stringEnd(b, from: j, body: &body) else { return nil }
        return (body, lead)
    }
}

/// An OSC or DCS body classified AS IT STREAMS — no byte of it is kept, so a string of any length is
/// classified exactly as a short one (xterm.js 6: `OscParser`, `DcsParser`, InputHandler's colour
/// and DECRQSS handlers). What a COLOUR query asks is kept as its SHAPE (`reports`: which colours, in
/// order — bounded), so the host can answer a long one exactly as xterm.js does (`equivalentQuery`).
struct StringBody: Sendable {
    let dcs: Bool
    /// A C1 code point introduced it.
    let c1: Bool
    /// xterm.js's `PAYLOAD_LIMIT`: a payload longer than this (in UTF-16 units) is not answered.
    static let payloadLimit = 10_000_000
    /// Most colour reports kept for `equivalentQuery`. xterm.js itself has no limit (one answer per
    /// valid `index;?` pair up to the payload limit — millions); past this the host answers the first
    /// `maxReports`, in order, and none of the rest: never two, never out of order.
    static let maxReports = 4096

    // DCS: the header, through DCS_ENTRY / DCS_PARAM / DCS_INTERMEDIATE / DCS_IGNORE, then data.
    private var state = 0                  // 0 entry, 1 param, 2 intermediate, 3 ignore, 4 passthrough
    private var prefix: UInt8?
    private var inter: [UInt8] = []
    private var final: UInt8 = 0
    // OSC: the identifier (digits only — anything else and xterm.js aborts it), then `;`-separated slots.
    private var id = -1                    // -1: no digit yet; -2: not an identifier
    private var payload = false
    private var slot = Slot()
    private var slotIndex = 0
    private var indexValid = false         // OSC 4: the pair's index slot was a valid colour index
    private var indexValue = 0             // …and its value
    private var answers = 0
    /// The colours asked, in order, at most `maxReports`: OSC 4 the index (0-255); OSC 10/11/12 256 plus
    /// the special colour's offset (0 foreground, 1 background, 2 cursor).
    private var reports: [UInt16] = []
    private var asks = false               // a payload slot that is exactly `?`
    private var lastQ = false              // the body so far ends in `?`
    private var units = 0                  // payload length in UTF-16 units
    /// The payload as the CLIENT's `TextDecoder` decodes it (the product never hands xterm.js bytes):
    /// invalid UTF-8 becomes U+FFFD, one unit per maximal subpart — so `units` counts what xterm.js's
    /// payload limit counts, invalid bytes included.
    private var utf8 = UTF8Units()

    private struct Slot: Sendable { var len = 0, digits = true, value = 0, q = false }

    init(dcs: Bool, c1: Bool) { self.dcs = dcs; self.c1 = c1 }

    /// One body byte (never a terminator). False: a DCS header met a non-ASCII code point, which
    /// xterm.js treats as an error — back to the ground state, at this byte.
    mutating func put(_ c: UInt8) -> Bool {
        if dcs { return putDCS(c) }
        if c < 0x20 {                                                  // C0 is ignored inside an OSC…
            if payload { units += utf8.interrupt() }                   // …but ends a partial character
            return true
        }
        lastQ = c == 0x3f
        guard payload else {
            if c == 0x3b { payload = true; slot = Slot() }
            else if (0x30...0x39).contains(c), id != -2 { id = min(max(id, 0) * 10 + Int(c - 0x30), 1_000_000) }
            else { id = -2 }
            return true
        }
        units += utf8.units(c)
        if c == 0x3b { closeSlot(); slot = Slot(); return true }
        slot.len += 1
        if (0x30...0x39).contains(c) { slot.value = min(slot.value * 10 + Int(c - 0x30), 1000) } else { slot.digits = false }
        slot.q = slot.len == 1 && c == 0x3f
        return true
    }

    private mutating func putDCS(_ c: UInt8) -> Bool {
        if state == 4 {
            if c != 0x7f { units += utf8.units(c) } else { units += utf8.interrupt() }   // DEL is ignored
            return true
        }
        if state == 3 { return true }
        if c < 0x20 || c == 0x7f { return true }                       // ignored in the header
        if c >= 0x80 { return false }
        switch (state, c) {
        case (0, 0x3c...0x3f): prefix = c; state = 1
        case (0...1, 0x30...0x3b): state = 1
        case (1, 0x3c...0x3f), (2, 0x30...0x3f): state = 3
        case (_, 0x20...0x2f): if inter.count < 3 { inter.append(c) }; state = 2
        default: final = c; state = 4                                  // 0x40-0x7E hooks the handler
        }
        return true
    }

    private mutating func closeSlot() {
        if slot.q { asks = true }
        if id == 4 {
            // `index ; spec` pairs: one answer per valid index (0-255) whose spec is exactly `?`.
            if slotIndex % 2 == 0 { indexValid = slot.len > 0 && slot.digits && slot.value <= 255; indexValue = slot.value }
            else if indexValid && slot.q { answers += 1; report(UInt16(indexValue)) }
        } else if (10...12).contains(id), id - 10 + slotIndex < 3, slot.q {
            answers += 1                                               // OSC 10 may ask 10, 11 and 12
            report(UInt16(256 + id - 10 + slotIndex))
        }
        slotIndex += 1
    }

    private mutating func report(_ r: UInt16) { if reports.count < Self.maxReports { reports.append(r) } }

    private var closed: StringBody { var s = self; if s.payload { s.closeSlot() }; return s }
    /// The payload's length as xterm.js counts it when the string ends: a character still unfinished
    /// there is one U+FFFD (the decoder flushes it before the terminator).
    private var endUnits: Int { units + utf8.pending }

    /// The answers xterm.js 6 gives this string, ended with `success` (BEL, ST, ESC — not CAN/SUB or a
    /// C1 code point) — nil when it is not query-like at all (DECRQSS/XTGETTCAP; OSC 4/10/11/12 with `?`).
    func replies(success: Bool) -> Int? {
        if dcs {
            guard state == 4, prefix == nil, final == 0x71, inter == [0x24] || inter == [0x2b] else { return nil }
            return inter == [0x24] && success && endUnits <= Self.payloadLimit ? 1 : 0
        }
        let s = closed
        guard [4, 10, 11, 12].contains(s.id), s.asks else { return nil }
        return success && s.endUnits <= Self.payloadLimit ? s.answers : 0
    }

    /// A short OSC asking exactly what this (answered) colour query asked, in the same order —
    /// `TermHostReplies` answers it as xterm.js answers the original: `ESC ] 4 ; i ; ? ; j ; ? … BEL`
    /// with each index normalised, or `ESC ] 10|11|12 ; ? ; ; ? BEL` with the unasked slots empty (which
    /// report nothing). nil for a DCS. At most `maxReports` answers.
    func equivalentQuery() -> [UInt8]? {
        guard !dcs else { return nil }
        let s = closed
        var q = "\u{1b}]"
        if s.id == 4 {
            q += "4" + s.reports.map { ";\($0);?" }.joined()
        } else if (10...12).contains(s.id) {
            let asked = Set(s.reports.map { Int($0) - 256 })
            let first = s.id - 10
            guard let last = asked.max() else { return nil }
            q += "\(s.id)" + (first...last).map { asked.contains($0) ? ";?" : ";" }.joined()
        } else {
            return nil
        }
        return Array((q + "\u{07}").utf8)
    }

    /// Whether tmux 3.7c answers this query itself, as the pane's terminal (MEASURED 2026-09-27 with a
    /// `-C` client attached): a DECRQSS, and an OSC 10/11 asking exactly one colour. It does NOT answer
    /// OSC 4, OSC 12, or OSC 10/11 with more than one `?` slot — which xterm.js answers, so the stripper
    /// leaves those in.
    var tmuxAnswers: Bool {
        if dcs { return true }
        let s = closed
        return (s.id == 10 || s.id == 11) && s.slotIndex == 1 && s.answers == 1
    }

    /// Could this string be a query at all: any DCS; any OSC with a `?` slot or ending in `?`.
    func urgent(_ replies: Int?) -> Bool {
        if replies != nil || dcs { return true }
        let s = closed
        return s.asks || s.lastQ
    }
}

/// UTF-16 units a WHATWG `TextDecoder` (the client's, `fatal: false`, streaming) produces for a byte
/// stream: a character counts when its last byte arrives (two units past the BMP), and invalid UTF-8
/// is one U+FFFD per MAXIMAL SUBPART — a lone continuation or an impossible lead byte one each, a
/// truncated sequence one, the byte that cut it then read afresh (the Encoding Standard's UTF-8
/// decoder, which xterm.js is fed through `term-stream.ts`). xterm.js's payload limit counts these units.
struct UTF8Units: Sendable {
    private var need = 0, seen = 0
    private var lower: UInt8 = 0x80, upper: UInt8 = 0xBF
    private var astral = false

    /// The units emitted once `c` is read.
    mutating func units(_ c: UInt8) -> Int {
        var n = 0
        if need > 0 {
            if c >= lower && c <= upper {
                lower = 0x80; upper = 0xBF
                seen += 1
                if seen == need { need = 0; seen = 0; return astral ? 2 : 1 }
                return 0
            }
            n = interrupt()                                            // U+FFFD, then `c` afresh
        }
        switch c {
        case 0x00...0x7F: return n + 1
        case 0xC2...0xDF: need = 1; astral = false
        case 0xE0...0xEF: need = 2; astral = false; if c == 0xE0 { lower = 0xA0 } else if c == 0xED { upper = 0x9F }
        case 0xF0...0xF4: need = 3; astral = true; if c == 0xF0 { lower = 0x90 } else if c == 0xF4 { upper = 0x8F }
        default: return n + 1                                          // 80-C1, F5-FF: U+FFFD
        }
        return n
    }

    /// A character left unfinished is ended by what comes next (a byte that is not its continuation):
    /// one U+FFFD. Returns the units emitted.
    mutating func interrupt() -> Int {
        guard need > 0 else { return 0 }
        need = 0; seen = 0; lower = 0x80; upper = 0xBF
        return 1
    }

    /// The units a character still unfinished would emit if the stream stopped here.
    var pending: Int { need > 0 ? 1 : 0 }
}
