package main

import (
	"encoding/binary"
	"errors"
	"math"
)

// THE LANE'S ENGINE (docs/superpowers/specs/2026-10-12-terminal-lane-design.md §2–§4): one END of the lane — the
// sender of this end's three streams and the receiver of the other end's. PURE: it is handed the time
// (milliseconds since the lane opened) and returns the packets to put on the data channel, so tests run two of them
// over a simulated link (rdev_lane_engine_test.go). Not safe for concurrent use: rdevLane holds a mutex around it.
// Mirrored by web/src/lib/lane.ts.
const (
	laneMessageMax         = 1 << 20
	laneRepairWindow       = 64
	laneHeldMax            = 512
	laneTailFirstMs        = 10
	laneTailSecondMs       = 40
	laneTailSecondPermille = 20
	laneRateMinPermille    = 100
	laneRateMaxPermille    = 500
	laneRateLossFactor     = 3
	laneFeedbackDelayMs    = 20
	laneFeedbackEvery      = 8
	laneFeedbackGapMs      = 10
	laneKeepaliveMs        = 1000
	laneReorderMs          = 10 // a symbol sent this much before the newest packet the peer echoes, and not decoded, is lost
	laneTimerFloorMs       = 40 // twice the receiver's longest feedback hold: an on-time ack never races the timer
	laneTimerInitialMs     = 200
	laneTimerMaxMs         = 1000
	laneBudgetBytesPerMs   = 8 // 64 kbit/s of PROACTIVE repair
	laneBudgetBurst        = 16384
	laneStuckMs            = 30000
	laneLossWindow         = 256
	laneProactiveOwedMax   = 4
	laneDecoderHistory     = 1024      // past laneHeldMax and a window: an ESI the sender may still repair is never pruned
	laneQueueTarget        = 16 * 1024 // queueTarget's floor: the short queue on top of the bytes in flight
	laneRateBucketMs       = 100
	laneRateBuckets        = 10 // the delivery rate is the bytes acknowledged over the last second
	laneBaseWindowSec      = 10 // the base round trip is the least pristine sample of the last 10 s
	lanePristineRing       = 8  // the send stamps of the last pristine polls, for the base round trip
)

// Packing order: control, input, terminal — small and urgent before bulk output.
var laneStreamPriority = [laneStreams]int{2, 1, 0}

var errLaneMessageSize = errors.New("lane: a message is 1 to 1048576 bytes")

type laneDelivery struct {
	stream int
	data   []byte
}

type laneOutStream struct {
	queue  [][]byte // framed messages (len u32 · message) not yet in a symbol
	taken  int      // bytes of queue[0] already in a symbol
	bytes  int      // pending bytes
	offset uint64   // the stream offset of the first pending byte
	// What the application handed and what the peer has acknowledged, in PAYLOAD bytes (`buffered`): every message
	// handed, and the messages not yet wholly acknowledged — their framed end offsets, oldest first — against the
	// framed offset the peer's cumulative acknowledgement has reached.
	handed      uint64
	messages    []laneOutMessage
	ackedOffset uint64
	ackedWhole  uint64 // payload bytes of the messages acknowledged whole (popped from `messages`)
}

type laneOutMessage struct {
	end  uint64 // the stream offset after this message's framed bytes
	size int    // its payload bytes
}

func (o *laneOutStream) take(n int) []byte {
	out := make([]byte, 0, n)
	for len(out) < n {
		head := o.queue[0][o.taken:]
		k := min(n-len(out), len(head))
		out = append(out, head[:k]...)
		o.taken += k
		if o.taken == len(o.queue[0]) {
			o.queue, o.taken = o.queue[1:], 0
		}
	}
	o.bytes -= n
	o.offset += uint64(n)
	return out
}

type laneInStream struct {
	offset   uint64            // the next byte to deliver
	segments map[uint64][]byte // chunks ahead of offset, keyed by their offset
	framed   []byte            // delivered bytes not yet a whole message
}

type laneHeldSymbol struct {
	bytes  []byte
	sentAt int64
	// Each stream's offset after what this symbol carried of it (`carried` says which): on the symbol's cumulative
	// acknowledgement the stream's `ackedOffset` reaches it.
	ends    [laneStreams]uint64
	carried [laneStreams]bool
}

type laneRepairPlan struct {
	first uint64
	count int
	n     int // repairs still to send over this window
}

type laneAckBucket struct {
	slot  int64 // now / laneRateBucketMs
	bytes int
}

type laneBaseSample struct {
	second int64
	ms     float64
}

type laneEngine struct {
	// ---- sending ----
	out            [laneStreams]laneOutStream
	held           map[uint64]laneHeldSymbol // ESIs in [heldFrom, nextESI)
	heldFrom       uint64                    // every ESI below is acknowledged and released
	nextESI        uint64
	knownAbove     map[uint64]bool // ESIs ≥ heldFrom the latest feedback reported decoded
	pkt            uint32
	seed           uint32
	srtt, rttvar   float64
	hasRTT         bool
	lossPermille   int // the peer's latest report
	tailDue        int64
	tail2Due       int64
	sinceRepair    int
	tokens         float64
	tokensAt       int64
	urgent         []laneRepairPlan // gap and timer repair
	proactiveOwed  int              // tail and proportional repair
	gapRepairedAt  map[uint64]int64
	timerDeadline  int64
	timerRTO       float64
	lastFeedbackAt int64
	// lastProgressAt: the cumulative acknowledgement last moved — or the link (re)connected (resetStuck). What `stuck`
	// and `stalledFor` measure from: a feedback that acknowledges nothing new is not progress. Measured from the last
	// FEEDBACK, a lane whose own packets never reached the peer stayed alive forever on the peer's keepalives
	// (2026-10-13: a phone's SCTP holding its keystrokes in its backoff after a network blink, the Mac's packets
	// still arriving — typing with no reply for minutes, neither end ever stuck).
	lastProgressAt int64
	ackBuckets     [laneRateBuckets]laneAckBucket // bytes the peer acknowledged, per 100 ms
	// THE BASE ROUND TRIP (queueTarget): the least round trip among PRISTINE samples — feedback echoing a packet sent
	// when the lane held nothing else unacknowledged — in per-second buckets over laneBaseWindowSec; with none in the
	// window the last stands. Every sample otherwise includes pion's queue for the lane, which the target itself
	// sizes: measured at 100 kbit/s (2026-10-12, term-slow-link-check), srtt climbed to 11 s, the target to 11 MB and
	// pion's queue to 132 KB — ten seconds of link in front of every keystroke's echo.
	pristineTS  [lanePristineRing]uint32
	pristineN   int
	baseSamples []laneBaseSample
	baseRTT     float64
	hasBase     bool
	// The newest FEEDBACK's pkt (`everFeedback`: one has arrived): only it describes the receiver (onFeedback).
	feedbackPkt  uint64
	everFeedback bool

	// ---- receiving ----
	decoder            *rlcDecoder
	highestESI         uint64
	everReceived       bool
	processed          map[uint64]bool
	cumESI             uint64 // the first ESI not yet known
	in                 [laneStreams]laneInStream
	delivered          []laneDelivery
	everPkt            bool
	highestPkt         uint64
	firstPkt           uint64
	pktSeen            [laneLossWindow]uint64 // pkt+1 last seen in each slot; 0 = never
	arrivals           int
	firstArrivalAt     int64
	feedbackNow        bool
	lastGapFeedbackAt  int64
	lastFeedbackSentAt int64
	lastTS             uint32
	lastAt             int64
	holeSince          int64
	// violated: the peer broke the protocol in a way no conforming sender can (consume) — stuck reads true at once, and
	// the glue closes the lane through the stuck path (an ordinary channel loss and rebuild).
	violated bool
}

// newLaneEngine starts every counter at `initial` (0 in the product; just below 2³² in the wrap test). `seed`
// starts the repair coefficients.
func newLaneEngine(seed uint32, initial uint64) *laneEngine {
	e := &laneEngine{
		held: map[uint64]laneHeldSymbol{}, heldFrom: initial, nextESI: initial, knownAbove: map[uint64]bool{},
		pkt: uint32(initial), seed: seed, tailDue: -1, tail2Due: -1, tokens: laneBudgetBurst,
		gapRepairedAt: map[uint64]int64{}, timerDeadline: -1, timerRTO: laneTimerInitialMs,
		decoder: newRLCDecoder(laneDecoderHistory), highestESI: initial, processed: map[uint64]bool{},
		cumESI: initial, highestPkt: initial, firstPkt: initial, lastGapFeedbackAt: math.MinInt64 / 2, holeSince: -1,
	}
	for s := range e.out {
		e.out[s].offset, e.out[s].ackedOffset = initial, initial
		e.in[s] = laneInStream{offset: initial, segments: map[uint64][]byte{}}
	}
	return e
}

// padLane zero-extends a symbol or repair to laneSymbolMax: the decoder's algebra needs one width.
func padLane(b []byte) []byte {
	out := make([]byte, laneSymbolMax)
	copy(out, b)
	return out
}

// ---- the application's side -----------------------------------------------------------------------------------

func (e *laneEngine) send(stream int, message []byte) error {
	if len(message) == 0 || len(message) > laneMessageMax {
		return errLaneMessageSize
	}
	framed := make([]byte, 4+len(message))
	binary.BigEndian.PutUint32(framed, uint32(len(message)))
	copy(framed[4:], message)
	o := &e.out[stream]
	o.queue = append(o.queue, framed)
	o.bytes += len(framed)
	o.handed += uint64(len(message))
	o.messages = append(o.messages, laneOutMessage{o.offset + uint64(o.bytes), len(message)})
	return nil
}

// buffered is what `stream` has been handed and the peer has not yet ACKNOWLEDGED — pending bytes and those in
// symbols its feedback has not yet covered cumulatively — in payload bytes, the frame prefixes excluded. It is what
// the channel reports as its bufferedAmount, and TermPacer's model of that number (TermPath): pion's counts bytes
// until SCTP acknowledges them, and `handed − buffered` must never decrease. Reporting the bytes not yet in a symbol
// read 0 whenever the lane had room, so the pacer handed a whole re-send into this stream's FIFO — where its
// reordering (the wire start and the tab on screen first) could not reach it: 18.7 s to a wire start and 20.4 s to
// an echo at 100 kbit/s (2026-10-12, term-slow-link-check) — and counted each message's 4-byte frame prefix, so
// `handed − buffered` stepped back by 4 per message and TermPath's rate wrapped to 9e20 B/s: `Int(bytes)` trapped
// the host.
func (e *laneEngine) buffered(stream int) int {
	o := &e.out[stream]
	acked := o.ackedWhole
	if len(o.messages) > 0 {
		// The oldest message not yet acknowledged whole: what the acknowledgement reached of its payload, past its prefix.
		head := o.messages[0]
		start := head.end - uint64(head.size) - 4
		if o.ackedOffset > start+4 {
			acked += min(o.ackedOffset-start-4, uint64(head.size))
		}
	}
	return int(o.handed - acked)
}

// acknowledged: the peer's cumulative acknowledgement reached `offset` of `stream` — the messages ending at or before
// it are acknowledged whole.
func (o *laneOutStream) acknowledged(offset uint64) {
	if offset <= o.ackedOffset {
		return
	}
	o.ackedOffset = offset
	for len(o.messages) > 0 && o.messages[0].end <= offset {
		o.ackedWhole += uint64(o.messages[0].size)
		o.messages = o.messages[1:]
	}
}

func (e *laneEngine) pending() bool {
	for s := range e.out {
		if e.out[s].bytes > 0 {
			return true
		}
	}
	return false
}

func (e *laneEngine) takeDelivered() []laneDelivery {
	d := e.delivered
	e.delivered = nil
	return d
}

// ---- receiving --------------------------------------------------------------------------------------------------

func (e *laneEngine) receive(packet []byte, now int64) {
	p, err := decodeLanePacket(packet)
	if err != nil {
		return
	}
	// THE NEWEST PACKET ONLY MEASURES THE PATH (spec §1, "The carrier"): the carrier is reliable, so SCTP's late copy of
	// a packet the lane counted lost — or a reorder — arrives after newer ones. It still delivers what it carries, but
	// cancels no loss (the estimate is of loss on FIRST transmission, what the lane's repair faces), leaves the echo on
	// the newest packet, and as a feedback gives no round-trip sample: its echo is as old as it is late.
	pkt := unwrapLane32(e.highestPkt, p.pkt)
	newest := e.notePkt(pkt)
	if newest {
		e.lastTS, e.lastAt = p.ts, now
	}
	// AN ESI PAST WHAT THE SENDER'S WINDOW COULD HOLD IS REFUSED (no conforming sender reaches cumESI + 512): it would
	// lift highestESI by up to 2³¹, and every feedback after would walk cumESI…highestESI — under the lane's lock, on
	// pion's read goroutine — and the decoder would prune everything below it.
	switch p.kind {
	case laneTypeSource:
		esi := unwrapLane32(e.highestESI, p.esi)
		if esi >= e.cumESI+laneDecoderHistory {
			return
		}
		e.noteData(now, esi, e.decoder.addSource(esi, padLane(p.payload)))
	case laneTypeRepair:
		if int(p.count) > laneRepairWindow {
			return
		}
		first := unwrapLane32(e.highestESI, p.esi)
		if first+uint64(p.count)-1 >= e.cumESI+laneDecoderHistory {
			return
		}
		e.noteData(now, first+uint64(p.count)-1, e.decoder.addRepair(first, int(p.count), p.seed, padLane(p.payload)))
	case laneTypeFeedback:
		e.onFeedback(p.feedback, now, newest, pkt)
	}
}

// notePkt counts a packet in the loss window if it is the newest yet, and says whether it was. One no newer than the
// highest seen changes nothing: a loss already counted stays counted.
func (e *laneEngine) notePkt(pkt uint64) bool {
	if e.everPkt && pkt <= e.highestPkt {
		return false
	}
	if !e.everPkt {
		e.firstPkt, e.everPkt = pkt, true
	}
	e.highestPkt = pkt
	e.pktSeen[pkt%laneLossWindow] = pkt + 1
	return true
}

// lossSeenPermille: the share of the peer's last 256 packets that never arrived, from the gaps in `pkt`.
func (e *laneEngine) lossSeenPermille() int {
	if !e.everPkt {
		return 0
	}
	expected := min(e.highestPkt-e.firstPkt+1, laneLossWindow)
	received := uint64(0)
	for i := uint64(0); i < expected; i++ {
		if pkt := e.highestPkt - i; e.pktSeen[pkt%laneLossWindow] == pkt+1 {
			received++
		}
	}
	return int((expected - received) * 1000 / expected)
}

// noteData: a SOURCE or REPAIR arrived, reaching up to `last`, and made `known` decoded.
func (e *laneEngine) noteData(now int64, last uint64, known []uint64) {
	if !e.everReceived || last > e.highestESI {
		e.highestESI = last
	}
	e.everReceived = true
	for _, esi := range known {
		if esi < e.cumESI || e.processed[esi] {
			continue
		}
		// PROCESSED ONLY ONCE CONSUMED: a symbol the decoder no longer holds, or one that does not parse, leaves its hole
		// — cumESI stops there and the stuck detector closes the lane — where marking it first acknowledged bytes no
		// stream was ever given, and that stream froze silently behind "connected".
		if symbol := e.decoder.get(esi); symbol == nil || !e.consume(symbol) {
			continue
		}
		e.processed[esi] = true
	}
	before := e.cumESI
	for e.processed[e.cumESI] {
		delete(e.processed, e.cumESI)
		e.cumESI++
	}
	if e.cumESI != before {
		e.holeSince = -1 // the oldest hole filled: one still open above it is a new one
	}
	if e.arrivals == 0 {
		e.firstArrivalAt = now
	}
	e.arrivals++
	if e.cumESI <= e.highestESI { // a hole below what has arrived
		if e.holeSince < 0 {
			e.holeSince = now
		}
		if now-e.lastGapFeedbackAt >= laneFeedbackGapMs {
			e.feedbackNow = true
		}
	} else {
		e.holeSince = -1
	}
}

// consume hands a known symbol's chunks to their streams, delivering every message whose bytes are now contiguous,
// and says whether it could. A chunk past what the sender's window could hold, or a frame longer than any message, is
// a broken peer (`violated`): kept, either would grow without bound — in the Mac's case inside the user's app.
func (e *laneEngine) consume(symbol []byte) bool {
	chunks, err := parseLaneSymbol(symbol)
	if err != nil {
		return false
	}
	for _, c := range chunks {
		if len(c.bytes) == 0 {
			continue // a zero-length chunk at the delivery offset would never advance it
		}
		in := &e.in[c.stream]
		offset := unwrapLane32(in.offset, c.offset)
		if offset+uint64(len(c.bytes)) <= in.offset {
			continue
		}
		// A conforming sender holds fewer than laneHeldMax symbols past what this end acknowledged, every byte of them
		// at most laneSymbolMax on: nothing it sends starts further ahead of the delivered offset than this.
		if offset > in.offset+laneHeldMax*laneSymbolMax {
			e.violated = true
			return false
		}
		in.segments[offset] = c.bytes
		for {
			segment, ok := in.segments[in.offset]
			if !ok {
				break
			}
			delete(in.segments, in.offset)
			in.offset += uint64(len(segment))
			in.framed = append(in.framed, segment...)
		}
		for len(in.framed) >= 4 {
			size := int(binary.BigEndian.Uint32(in.framed))
			if size > laneMessageMax {
				e.violated = true
				return false
			}
			if len(in.framed) < 4+size {
				break
			}
			e.delivered = append(e.delivered, laneDelivery{int(c.stream), append([]byte(nil), in.framed[4:4+size]...)})
			in.framed = in.framed[4+size:]
		}
	}
	return true
}

// onFeedback: the peer's report on what it decoded — the sender's acknowledgement, loss and round trip. A feedback
// that is not the `newest` packet seen gives no round-trip sample (receive). A LATE FEEDBACK — no newer than the newest
// FEEDBACK seen (`pkt`): SCTP's copy of one the lane counted lost, guaranteed under loss on a reliable carrier — applies
// only its cumulative acknowledgement. Its loss, its ranges and the gap repairs they would plan describe the receiver
// as it was: applied, they overwrote the newer report's loss and replanned repair from a stale picture of the holes.
// Two gates, one stricter: the newest packet of any kind is always the newest feedback too, so a feedback that may
// give a round-trip sample may always apply its ranges and loss, never the other way round.
func (e *laneEngine) onFeedback(f laneFeedback, now int64, newest bool, pkt uint64) {
	e.lastFeedbackAt = now
	current := !e.everFeedback || pkt > e.feedbackPkt
	if current {
		e.feedbackPkt, e.everFeedback = pkt, true
	}
	if sample := int64(uint32(now)-f.echoTS) - int64(f.held); newest && sample >= 0 && sample < 60_000 {
		e.updateRTT(float64(sample))
		if e.isPristine(f.echoTS) {
			e.noteBase(now, float64(sample))
		}
	}
	if current {
		e.lossPermille = int(f.lossPermille)
	}
	cum := min(unwrapLane32(e.heldFrom, f.cumESI), e.nextESI)
	if cum > e.heldFrom {
		released := 0
		for esi := e.heldFrom; esi < cum; esi++ {
			h := e.held[esi]
			released += laneHeaderBytes + 4 + len(h.bytes)
			for s := range h.carried {
				if h.carried[s] {
					e.out[s].acknowledged(h.ends[s])
				}
			}
			delete(e.held, esi)
		}
		e.heldFrom = cum
		e.lastProgressAt = now
		e.timerRTO = min(e.rtoBase(), laneTimerMaxMs) // progress: the backoff starts over, under the cap
		e.noteAcked(now, released)
	}
	if e.nextESI == e.heldFrom {
		e.timerDeadline = -1 // nothing unacknowledged: nothing to time
	}
	if current {
		e.knownAbove = map[uint64]bool{}
		highestKnown := e.heldFrom // exclusive
		for _, r := range f.ranges {
			start := unwrapLane32(e.heldFrom, r.start)
			for i := uint64(0); i < uint64(r.length); i++ {
				if esi := start + i; esi >= e.heldFrom && esi < e.nextESI {
					e.knownAbove[esi] = true
					highestKnown = max(highestKnown, esi+1)
				}
			}
		}
		echoAt := now - int64(uint32(now)-f.echoTS) // when this end sent the newest packet the peer echoes
		e.planGapRepairs(e.missingESIs(highestKnown, echoAt), now)
	}
	for start := range e.gapRepairedAt {
		if start < e.heldFrom {
			delete(e.gapRepairedAt, start)
		}
	}
}

// missingESIs: the unacknowledged ESIs the latest feedback shows lost — not reported decoded, and either below one it
// reports decoded or first sent more than laneReorderMs before the newest packet it echoes (RACK). The second is how a
// lost burst END — symbols and their tail repairs — shows: the peer decoded nothing above it, so no range reveals it.
func (e *laneEngine) missingESIs(highestKnown uint64, echoAt int64) []uint64 {
	var missing []uint64
	for esi := e.heldFrom; esi < e.nextESI; esi++ {
		if !e.knownAbove[esi] && (esi < highestKnown || e.held[esi].sentAt+laneReorderMs < echoAt) {
			missing = append(missing, esi)
		}
	}
	return missing
}

// planGapRepairs: k + 1 repairs per window of ≤ 64 holding k missing symbols, each window at most once per rtoBase.
func (e *laneEngine) planGapRepairs(missing []uint64, now int64) {
	interval := int64(e.rtoBase())
	for i := 0; i < len(missing); {
		first := missing[i]
		end := min(first+laneRepairWindow, e.nextESI)
		k := 0
		for i < len(missing) && missing[i] < end {
			k++
			i++
		}
		if at, ok := e.gapRepairedAt[first]; ok && now-at < interval {
			continue
		}
		e.gapRepairedAt[first] = now
		e.urgent = append(e.urgent, laneRepairPlan{first, int(end - first), k + 1})
	}
}

func (e *laneEngine) rtoBase() float64 {
	if !e.hasRTT {
		return laneTimerInitialMs
	}
	return e.srtt + max(4*e.rttvar, laneTimerFloorMs)
}

func (e *laneEngine) noteAcked(now int64, bytes int) {
	slot := now / laneRateBucketMs
	b := &e.ackBuckets[slot%laneRateBuckets]
	if b.slot != slot {
		b.slot, b.bytes = slot, 0
	}
	b.bytes += bytes
}

// queueTarget is the most the data channel may hold for the lane. pion counts bytes until SCTP ACKNOWLEDGES them,
// so a fixed ceiling would cap throughput at that ceiling per round trip; this is the bytes in flight at the
// delivery rate, twice over, plus a 16 KB queue — urgent packets wait behind little, and throughput can double per
// round trip until SCTP's own window or the 512 held symbols stop it.
//
// The round trip is the BASE one (`baseRTT`), never srtt: srtt carries pion's queue, which this target sizes — a
// loop that ran the target to 11 MB. The rate is the bytes acknowledged over the LAST SECOND, never the best 100 ms:
// a hole the receiver fills late releases everything above it in one feedback — 161 KB in one 100 ms bucket at a
// 12.5 KB/s link — and a best bucket read that as the link's rate (2026-10-12, term-slow-link-check).
func (e *laneEngine) queueTarget(now int64) int {
	slot := now / laneRateBucketMs
	acked := 0
	for _, b := range e.ackBuckets {
		if slot-b.slot < laneRateBuckets {
			acked += b.bytes
		}
	}
	// Before the first pristine sample the INITIAL timer stands in for the base — never srtt, which carries the queue
	// this target sizes: a lane opening into a burst took its 1.2 s srtt and asked for 967 KB (2026-10-12, measured).
	rtt := float64(laneTimerInitialMs)
	if e.hasBase {
		rtt = e.baseRTT
	}
	return laneQueueTarget + int(2*float64(acked)/(laneRateBuckets*laneRateBucketMs)*rtt)
}

// markPristine: this poll's packets went into a lane holding nothing else unacknowledged — their echo measures the
// path, not the queue — so their send stamp is remembered for isPristine.
func (e *laneEngine) markPristine(now int64) {
	e.pristineTS[e.pristineN%lanePristineRing] = uint32(now)
	e.pristineN++
}

func (e *laneEngine) isPristine(echoTS uint32) bool {
	for i := 0; i < min(e.pristineN, lanePristineRing); i++ {
		if e.pristineTS[i] == echoTS {
			return true
		}
	}
	return false
}

// noteBase: a pristine round-trip sample. The least of each second is kept for laneBaseWindowSec; the base is the
// least in the window, or the last base when the window is empty (a long saturated stretch) — never zero FOR LACK OF
// SAMPLES. A 0 ms sample on a sub-millisecond LAN is a real base of 0, and the target is then its 16 KB floor.
func (e *laneEngine) noteBase(now int64, sample float64) {
	second := now / 1000
	if n := len(e.baseSamples); n > 0 && e.baseSamples[n-1].second == second {
		e.baseSamples[n-1].ms = min(e.baseSamples[n-1].ms, sample)
	} else {
		e.baseSamples = append(e.baseSamples, laneBaseSample{second, sample})
	}
	kept := e.baseSamples[:0]
	for _, s := range e.baseSamples {
		if second-s.second <= laneBaseWindowSec {
			kept = append(kept, s)
		}
	}
	e.baseSamples = kept
	e.baseRTT, e.hasBase = e.baseSamples[0].ms, true
	for _, s := range e.baseSamples[1:] {
		e.baseRTT = min(e.baseRTT, s.ms)
	}
}

func (e *laneEngine) updateRTT(sample float64) {
	if !e.hasRTT {
		e.srtt, e.rttvar, e.hasRTT = sample, sample/2, true
		return
	}
	e.rttvar = 0.75*e.rttvar + 0.25*math.Abs(e.srtt-sample)
	e.srtt = 0.875*e.srtt + 0.125*sample
}

// ---- sending ----------------------------------------------------------------------------------------------------

// poll returns the packets to send now, `room` being the bytes pion's queue may still take; feedback ignores it.
func (e *laneEngine) poll(now int64, room int) [][]byte {
	var packets [][]byte
	timed := false // a source or repair went: the timer re-arms from now
	emit := func(p []byte) {
		packets = append(packets, p)
		room -= len(p)
		timed = timed || p[0] != laneTypeFeedback
	}
	e.refill(now)
	if e.feedbackDue(now) {
		emit(e.feedbackPacket(now))
	}
	if e.timerDeadline >= 0 && now >= e.timerDeadline && e.nextESI > e.heldFrom {
		// Nothing sent for a whole timeout with data unacknowledged: repair the OLDEST window — where a hole below an
		// acknowledged newest symbol sits — and the newest, where a lost tail sits, when they differ.
		oldest := min(e.nextESI-e.heldFrom, laneRepairWindow)
		e.urgent = append(e.urgent, laneRepairPlan{e.heldFrom, int(oldest), 1})
		if first, count := e.newestWindow(); first != e.heldFrom {
			e.urgent = append(e.urgent, laneRepairPlan{first, count, 1})
		}
		e.timerRTO = min(e.timerRTO*2, laneTimerMaxMs)
		e.timerDeadline = now + int64(e.timerRTO)
	}
	for len(e.urgent) > 0 {
		first, count := e.clampWindow(e.urgent[0].first, e.urgent[0].count)
		if count == 0 {
			e.urgent = e.urgent[1:]
			continue
		}
		if e.repairSize(first, count) > room {
			break
		}
		emit(e.repairPacket(first, count, now))
		if e.urgent[0].n--; e.urgent[0].n == 0 {
			e.urgent = e.urgent[1:]
		}
	}
	for e.pending() && e.nextESI-e.heldFrom < laneHeldMax && room >= laneHeaderBytes+4+2+laneChunkHeader+1 {
		symbol, ends, carried := e.packSymbol(room - laneHeaderBytes - 4)
		esi := e.nextESI
		e.nextESI++
		e.held[esi] = laneHeldSymbol{bytes: symbol, sentAt: now, ends: ends, carried: carried}
		emit(encodeLaneSource(e.nextPkt(), uint32(now), uint32(esi), symbol))
		if e.sinceRepair++; e.sinceRepair >= 1000/e.ratePermille() {
			e.sinceRepair = 0
			e.owe()
		}
		e.tailDue, e.tail2Due = now+laneTailFirstMs, -1
		if e.lossPermille >= laneTailSecondPermille {
			e.tail2Due = now + laneTailSecondMs
		}
	}
	if e.tailDue >= 0 && now >= e.tailDue {
		e.tailDue = -1
		e.owe()
	}
	if e.tail2Due >= 0 && now >= e.tail2Due {
		e.tail2Due = -1
		e.owe()
	}
	if e.nextESI == e.heldFrom {
		e.proactiveOwed = 0 // nothing left to protect
	}
	for e.proactiveOwed > 0 {
		first, count := e.newestWindow()
		size := e.repairSize(first, count)
		if size > room || float64(size) > e.tokens {
			break
		}
		e.tokens -= float64(size)
		e.proactiveOwed--
		emit(e.repairPacket(first, count, now))
	}
	switch {
	case e.nextESI == e.heldFrom:
		e.timerDeadline = -1
	case timed:
		e.timerDeadline = now + int64(e.timerRTO)
	}
	// A lone packet into an otherwise acknowledged lane (a keystroke's echo, a keepalive): its round trip is the path's.
	if len(packets) > 0 && len(packets) <= 2 && e.nextESI-e.heldFrom <= 1 {
		e.markPristine(now)
	}
	return packets
}

// packSymbol takes pending stream bytes — control, then input, then terminal — into one symbol of at most `limit`,
// and says where each stream it carried now ends.
func (e *laneEngine) packSymbol(limit int) (symbol []byte, ends [laneStreams]uint64, carried [laneStreams]bool) {
	space := min(limit, laneSymbolMax) - 2
	var chunks []laneChunk
	for _, s := range laneStreamPriority {
		o := &e.out[s]
		for o.bytes > 0 && space > laneChunkHeader {
			n := min(space-laneChunkHeader, o.bytes)
			offset := uint32(o.offset)
			chunks = append(chunks, laneChunk{byte(s), offset, o.take(n)})
			space -= laneChunkHeader + n
			ends[s], carried[s] = o.offset, true
		}
	}
	return buildLaneSymbol(chunks), ends, carried
}

func (e *laneEngine) nextPkt() uint32 {
	p := e.pkt
	e.pkt++
	return p
}

func (e *laneEngine) owe() { e.proactiveOwed = min(e.proactiveOwed+1, laneProactiveOwedMax) }

func (e *laneEngine) ratePermille() int {
	return min(max(laneRateLossFactor*e.lossPermille, laneRateMinPermille), laneRateMaxPermille)
}

func (e *laneEngine) refill(now int64) {
	if now > e.tokensAt {
		e.tokens = math.Min(laneBudgetBurst, e.tokens+float64(now-e.tokensAt)*laneBudgetBytesPerMs)
		e.tokensAt = now
	}
}

// newestWindow: the newest ≤ 64 unacknowledged symbols — what tail, proportional and timer repair cover.
func (e *laneEngine) newestWindow() (uint64, int) {
	first := e.heldFrom
	if e.nextESI-first > laneRepairWindow {
		first = e.nextESI - laneRepairWindow
	}
	return first, int(e.nextESI - first)
}

// clampWindow trims a planned window to what is still held (acknowledgements may have arrived since).
func (e *laneEngine) clampWindow(first uint64, count int) (uint64, int) {
	end := first + uint64(count)
	first = max(first, e.heldFrom)
	end = min(end, e.nextESI, first+laneRepairWindow)
	if end <= first {
		return first, 0
	}
	return first, int(end - first)
}

func (e *laneEngine) repairSize(first uint64, count int) int {
	width := 0
	for i := 0; i < count; i++ {
		width = max(width, len(e.held[first+uint64(i)].bytes))
	}
	return laneHeaderBytes + 10 + width
}

func (e *laneEngine) repairPacket(first uint64, count int, now int64) []byte {
	symbols := make([][]byte, count)
	for i := range symbols {
		symbols[i] = e.held[first+uint64(i)].bytes
	}
	seed := e.seed
	e.seed = rlcNextSeed(seed)
	return encodeLaneRepair(e.nextPkt(), uint32(now), uint32(first), uint16(count), seed, rlcRepair(symbols, seed))
}

func (e *laneEngine) feedbackDue(now int64) bool {
	if !e.everReceived {
		return false
	}
	return e.feedbackNow || e.arrivals >= laneFeedbackEvery ||
		(e.arrivals > 0 && now-e.firstArrivalAt >= laneFeedbackDelayMs) ||
		now-e.lastFeedbackSentAt >= laneKeepaliveMs
}

func (e *laneEngine) feedbackPacket(now int64) []byte {
	f := laneFeedback{cumESI: uint32(e.cumESI), lossPermille: uint16(e.lossSeenPermille()), echoTS: e.lastTS,
		held: uint16(min(max(now-e.lastAt, 0), 65535))}
	for esi := e.cumESI + 1; esi <= e.highestESI && len(f.ranges) < laneRangesMax; {
		if !e.decoder.has(esi) {
			esi++
			continue
		}
		start := esi
		for esi <= e.highestESI && e.decoder.has(esi) && esi-start < 65535 {
			esi++
		}
		f.ranges = append(f.ranges, laneRange{uint32(start), uint16(esi - start)})
	}
	if e.cumESI <= e.highestESI {
		e.lastGapFeedbackAt = now
	}
	e.arrivals, e.feedbackNow, e.lastFeedbackSentAt = 0, false, now
	return encodeLaneFeedback(e.nextPkt(), uint32(now), f)
}

// nextWake is when poll should run next (−1: nothing scheduled — a send or an arrival will call it).
func (e *laneEngine) nextWake(now int64) int64 {
	wake := int64(-1)
	at := func(t int64) {
		if t >= 0 && (wake < 0 || t < wake) {
			wake = t
		}
	}
	if e.everReceived {
		if e.arrivals > 0 {
			at(e.firstArrivalAt + laneFeedbackDelayMs)
		}
		at(e.lastFeedbackSentAt + laneKeepaliveMs)
	}
	at(e.tailDue)
	at(e.tail2Due)
	at(e.timerDeadline)
	if e.proactiveOwed > 0 && e.nextESI > e.heldFrom {
		first, count := e.newestWindow()
		if need := float64(e.repairSize(first, count)) - e.tokens; need > 0 {
			at(now + int64(math.Ceil(need/laneBudgetBytesPerMs)))
		}
	}
	if wake >= 0 && wake < now {
		wake = now
	}
	return wake
}

// stuck: 30 s holding unacknowledged data with no PROGRESS (stalledFor), or 30 s with a hole that cannot be filled —
// or at once, a peer that broke the protocol (`violated`). The GLUE acts on it only on a connected link (an outage is
// not a stuck lane) and calls resetStuck when the link connects.
func (e *laneEngine) stuck(now int64) bool {
	if e.violated {
		return true
	}
	if e.stalledFor(now) >= laneStuckMs {
		return true
	}
	return e.holeSince >= 0 && now-e.holeSince >= laneStuckMs
}

// stalledFor is how long the oldest unacknowledged symbol has waited for progress — since it was sent, the cumulative
// acknowledgement last moved, or the link last connected, whichever is latest — or −1 with nothing unacknowledged.
func (e *laneEngine) stalledFor(now int64) int64 {
	if e.nextESI == e.heldFrom {
		return -1
	}
	return now - max(e.lastProgressAt, e.held[e.heldFrom].sentAt)
}

func (e *laneEngine) resetStuck(now int64) {
	e.lastFeedbackAt = now
	e.lastProgressAt = now
	if e.holeSince >= 0 {
		e.holeSince = now
	}
}
