package main

import (
	"encoding/json"
	"fmt"
	"math/rand"
	"os"
	"strconv"
	"sync"
	"sync/atomic"

	"github.com/pion/webrtc/v4"
)

// The two channels this feature adds, both created by the OFFER path alongside rdev's three.
//
// DELIBERATELY NOT IN rdevChannelLabels, whose INDEX is the C ABI's channel slot: appending to that
// slice would renumber terminal/input/control and break every existing send.
const (
	dcVideoChannelLabel    = "video"
	dcFeedbackChannelLabel = "video-feedback"
)

// Fixed for increment 1. Adaptivity is increment 2, and a constant here is what makes that
// adaptivity measurable against a known baseline rather than against a moving one.
//
// The values come from the spike sweep: window 16 symbols is about four frames at rdev's ~4-symbol
// access units, and one repair per frame measured 25% overhead holding frame loss to 0.33-0.39% at
// 2% packet loss. Keyframes get two, because loss probability scales with frame size.
const (
	dcDefaultWindowLen         = 16
	dcDefaultRepairPerFrame    = 1
	dcDefaultRepairPerKeyframe = 2
	// Fraction of a keyframe's symbols emitted as repair. 0.5 is the cap `repairRateForLoss` reaches
	// only at heavy measured loss: a keyframe always gets what a delta frame gets at its worst,
	// because a lost keyframe under an infinite GOP does not cost one frame, it costs every frame
	// until another one survives. Paid rarely — keyframes are on demand, so a healthy session emits
	// almost none.
	dcKeyframeRepairRate = 0.5

	// ADMISSION CONTROL — the bound that keeps the channel alive.
	//
	// SCTP QUEUES, AND WE CANNOT WITHDRAW WHAT WE HAND IT. Verified in pion/sctp: the pending queue
	// holds chunks awaiting cwnd (association.go), and `checkPartialReliabilityStatus` — the only
	// place a chunk is ever abandoned — runs at first transmission and at retransmission, never for
	// something still queued. `maxRetransmits: 0` bounds REDELIVERY, not the wait to be delivered
	// once. And `maxPacketLifeTime` would not help either: the lifetime clock (`chunkPayload.since`)
	// is set at first transmission, so a queued chunk has no clock running at all.
	//
	// So the only place staleness can be bounded is HERE, before the handoff. Nothing downstream will
	// ever drop a frame for being old, and the observed consequence was fatal rather than degrading:
	// buffered depth ran 39kB -> 1.1MB inside one five-second window and took the peer connection with
	// it ("PeerConnection disconnected"). A frame queued behind a megabyte cannot be presented on time
	// anyway, so enqueueing it only delays every frame behind it. That is self-inflicted head-of-line
	// blocking, and this is the line that refuses it.
	//
	// WHOLE FRAMES, NEVER PARTIAL ONES. Half a frame is undecodable and its bytes are pure waste; the
	// receiver's own dependency check will notice the gap and ask for a keyframe through the control
	// channel, which is a path that already exists and is tested.
	//
	// HYSTERESIS, because a single threshold at the drain rate oscillates: shedding stops only once
	// the queue is genuinely clear, not the instant it dips below the mark.
	//
	// The numbers are chosen against measurement, not taste: a healthy relayed session's high-water
	// sat at 29-40kB, and the fatal run reached 1.1MB. 192kB is far above normal operation and far
	// below fatal — about 0.75s of video at 2Mbit/s, which is already more staleness than anyone
	// wants and is meant as a backstop rather than a working point.
	dcSendHighWaterBytes = 192 * 1024
	dcSendLowWaterBytes  = 64 * 1024
)

type dcDelivery struct {
	mutex    sync.Mutex
	video    *webrtc.DataChannel
	feedback *webrtc.DataChannel
	streams  map[int]*dcVideoStream
	/// sourceIndex -> source id, announced to the client. See announce().
	names    map[uint16]string
	// MONOTONIC AND NEVER REUSED — see TestReleasedSourceIndexIsNotReused. A recycled index would let
	// a late symbol from a retired source decode into its replacement.
	nextSourceIndex uint16

	// The client's tab is backgrounded. STOPS EMITTING WITHOUT UNROUTING, so the tab coming back is
	// not a renegotiation — the same shape as the RTP path's sink drop.
	hidden atomic.Bool

	sent      atomic.Uint64
	failed    atomic.Uint64
	notOpen   atomic.Uint64
	sourceSym atomic.Uint64
	repairSym atomic.Uint64
	// WIRE BYTES, counted because SYMBOL COUNTS CANNOT SEE THE PADDING. Under v4 every symbol went out
	// at the full 1236 bytes whatever the frame held, so `src=299 repair=299` read as a balanced 100%
	// overhead while the real split on a near-static window was ~27 bytes of video against 1200 bytes
	// of zeroes. Bytes are what the link is actually charged.
	sentBytes atomic.Uint64
	// Retransmission: symbols asked for, symbols actually re-sent, and requests for symbols no longer
	// in history. The third is the one that says the history is too short.
	nackedSymbols atomic.Uint64
	retransmitted atomic.Uint64
	nackMisses    atomic.Uint64
	// HOW DEEP THE SEND BUFFER GETS, which is the one measurement that separates "this link is far
	// away" from "we are sending faster than it drains". A growing backlog explains a late
	// retransmission, a lost symbol (SCTP is unordered with no retransmits here, so it discards under
	// pressure) and a slow-feeling link all at once — and it is the signature of overdriving.
	sendBufferedMax atomic.Uint64
	/// True while shedding: the send queue passed the high-water mark and has not yet drained to the
	/// low one. Frames are refused entirely for the duration.
	shedding atomic.Bool
	/// Frames refused by admission control, and the symbols they would have cost.
	sheddedFrames  atomic.Uint64
	sheddedSymbols atomic.Uint64
	rtxBufferedMax  atomic.Uint64
	// REPAIR BYTES, SEPARATELY FROM SYMBOL COUNTS. The overhead was reported as a ratio of symbol
	// counts, and on a static window that read 29% while repair was 71% of the wire — every symbol
	// counted the same whether it carried 470 bytes or 1240.
	repairBytes atomic.Uint64
	hiddenAU   atomic.Uint64
	seededLoss atomic.Uint64

	// TEST-ONLY, and read once at construction so it cannot drift mid-session.
	lossBasisPoints int
	lossMutex       sync.Mutex
	lossRNG         *rand.Rand
}

func newDCDelivery(video, feedback *webrtc.DataChannel) *dcDelivery {
	delivery := &dcDelivery{
		video: video, feedback: feedback,
		streams:         map[int]*dcVideoStream{},
		names:           map[uint16]string{},
		lossBasisPoints: dcEnvInt("RDEV_DC_LOSS_BP", 0),
		lossRNG:         rand.New(rand.NewSource(int64(dcEnvInt("RDEV_DC_LOSS_SEED", 1741)))),
	}
	if feedback != nil {
		feedback.OnMessage(func(message webrtc.DataChannelMessage) {
			delivery.onFeedback(append([]byte(nil), message.Data...))
		})
		// REPLAYED ON OPEN. Routing precedes SCTP, so the announcement made at routing time reaches
		// nobody; without this the client decodes every symbol and discards every frame.
		feedback.OnOpen(func() { delivery.announce() })
	}
	return delivery
}

// onFeedback prints one client report.
//
// THE CLIENT'S VIEW IS THE ONLY ONE THAT CAN SAY WHETHER THE PICTURE ARRIVED. The host knows what it
// sent; only the receiver knows what was assembled, what the code repaired, and what was lost — the
// same reason `[rx]` exists for the RTP path.
//
// PRINTED, NEVER ACTED ON, in increment 1. Adaptive FEC reads these in increment 2; reporting first
// means the numbers driving that loop have been looked at before anything depends on them.
func (delivery *dcDelivery) onFeedback(payload []byte) {
	var report struct {
		Type             string  `json:"t"`
		Source           string  `json:"source"`
		Emitted          int     `json:"emitted"`
		FramesLost       int     `json:"framesLost"`
		FrameLossPercent float64 `json:"frameLossPercent"`
		// LOSS SINCE THE LAST REPORT, which is what the redundancy follows. The cumulative figure
		// above is for reading; a lifetime average cannot answer "how is this link RIGHT NOW", and a
		// controller driven by it is inert on a link that degrades after a clean start.
		RecentLossPercent float64 `json:"recentLossPercent"`
		// FRAMES THAT ARRIVED AFTER THE RECEIVER HAD GIVEN UP ON THEM. The one counter that separates
		// a link that LOSES from a link that STALLS — and over a TCP tunnel, which retransmits
		// underneath us, stalling is what actually happens. A frame counted here was never lost: it
		// was late, and no amount of redundancy or retransmission can repair lateness.
		TooLate int `json:"tooLate"`
		// How many frames the receiver is currently willing to wait past a hole. Adaptive: it grows on
		// evidence that a frame arrived after being given up on, so a rising figure IS the link
		// telling you it stalls.
		ReorderFrames int `json:"reorderFrames"`
		RepairedFrames   int     `json:"repairedFrames"`
		RecoveredSymbols int     `json:"recoveredSymbols"`
		// Frames that ARRIVED INTACT and were refused because the frame they reference never did.
		// Distinct from a loss: the link delivered these, the decode chain could not use them.
		Undecodable int `json:"undecodable"`
		// The ARQ round trip measured in FRAMES — directly comparable with the receiver's reorder
		// window, which is counted in the same unit. A p95 at or above that window means every
		// retransmission is arriving after its frame has already been given up on, and the requests
		// are pure cost.
		ARQRoundTripFrames    int `json:"arqRoundTripFrames"`
		ARQRoundTripFramesP95 int `json:"arqRoundTripFramesP95"`
		ARQAnswered           int `json:"arqAnswered"`
		// Frames whose contents did not match the hash the sender computed over them. NON-ZERO IS A
		// REAL FAULT, not a tuning signal: the code solved for a symbol and got the wrong answer, and
		// before this existed those frames went to the decoder as though they were video.
		CorruptFrames    int `json:"corruptFrames"`
		CorruptKeyframes int `json:"corruptKeyframes"`
		// Frames emitted after a gap: a loss the code could not repair and ARQ could not retrieve in
		// time. Each one leaves the decoder referencing a picture it never had, which looks exactly
		// like data corruption and is not.
		Discontinuities int `json:"discontinuities"`
		DuplicatePercent float64 `json:"duplicatePercent"`
		OverheadPercent  float64 `json:"overheadPercent"`
		// Main-thread milliseconds per second the CLIENT spent parsing, assembling and solving this
		// channel's symbols. The receive path is not on a worker, so this is the one number that can
		// tell "the transport stalled" from "the tab ran out of main thread".
		CPUMsPerS float64 `json:"cpuMsPerS"`
		// The worst the client's MAIN THREAD ran late since the last report. Every other number here
		// describes the transport or the decoder, and all of them read healthy while a tab is wedged;
		// this is the only one that describes the thread. It rides THIS line because the `[rx]` line
		// does not print on the DataChannel arm at all.
		MainLateMs float64 `json:"mainLateMs"`
		// WHICH ICE PATH WON — "p2p", "relay", or empty when the client could not tell.
		//
		// It rides THIS line for the same reason MainLateMs does: `via=` lives on the `[rx]` line, and
		// `[rx]` does not print on the DataChannel arm at all, so the moment the channel takes over
		// the transport becomes invisible. A relayed session and a direct one produce entirely
		// different numbers from identical code, and nothing else in the host log says which one was
		// measured.
		Via string `json:"via"`
		// A retransmission request: the source index it concerns and the ESIs it wants again.
		Index uint16   `json:"index"`
		ESIs  []uint32 `json:"esis"`
	}
	if err := json.Unmarshal(payload, &report); err != nil {
		return
	}
	// THE CLIENT ASKS, WHICH IS THE ONLY RACE-FREE ORDER. Announcing on channel-open loses to a client
	// that has not attached its listener yet — the host considers the channel open before the client's
	// `ondatachannel` has run, and the announcement goes nowhere. Measured: 1,195 symbols arriving,
	// decoding perfectly, and every frame discarded for want of a mapping.
	// THE RECEIVER'S LOSS SETS THE REDUNDANCY. Reported in increment 1 and acted on here: a link that
	// loses nothing pays the floor, and one that loses a lot pays up to the cap and no more.
	if report.Type == "dc-report" && report.Source != "" {
		delivery.setRepairRateFor(report.Source, repairRateForLoss(report.RecentLossPercent))
	}
	if report.Type == "dc-nack" {
		delivery.retransmit(report.Index, report.ESIs)
		return
	}
	if report.Type == "dc-map-request" {
		delivery.announce()
		return
	}
	if report.Type != "dc-report" {
		return
	}
	// ABSENT MEANS UNKNOWN, never "p2p". The client reports what `getStats` told it, and a browser
	// that has not resolved a candidate pair yet has said nothing rather than said "direct".
	via := report.Via
	if via == "" {
		via = "?"
	}
	fmt.Printf("[dc-rx] %s via=%s emitted=%d lost=%d (%.2f%%) repaired=%d recovered=%d overhead=%.1f%% cpu=%.0fms/s mainLate=%.0fms\n",
		report.Source, via, report.Emitted, report.FramesLost, report.FrameLossPercent,
		report.RepairedFrames, report.RecoveredSymbols, report.OverheadPercent, report.CPUMsPerS,
		report.MainLateMs)
	if report.TooLate > 0 {
		fmt.Printf("[dc-rx] %s tooLate=%d (waiting %d frames) — frames that ARRIVED after being given "+
			"up on; these were late, not lost, and only a longer wait repairs lateness\n",
			report.Source, report.TooLate, report.ReorderFrames)
	}
	if report.ARQAnswered > 0 {
		fmt.Printf("[dc-rx] %s arq round trip p50=%d p95=%d frames (over %d answered)\n",
			report.Source, report.ARQRoundTripFrames, report.ARQRoundTripFramesP95, report.ARQAnswered)
	}
	if report.Undecodable > 0 {
		fmt.Printf("[dc-rx] %s undecodable=%d — frames refused because their reference never arrived\n",
			report.Source, report.Undecodable)
	}
	if report.Discontinuities > 0 {
		fmt.Printf("[dc-rx] %s gaps=%d — frames the decoder had to render without their reference\n",
			report.Source, report.Discontinuities)
	}
	if report.CorruptFrames > 0 {
		fmt.Printf("[dc-rx] %s CORRUPT frames=%d keyframes=%d — the code solved for a symbol and got "+
			"the wrong answer; these did NOT reach the decoder\n",
			report.Source, report.CorruptFrames, report.CorruptKeyframes)
	}
	// NEAR-TOTAL DUPLICATE SYMBOL IDS MEAN THE SENDER IS NOT NUMBERING THEM, so the decoder is
	// overwriting one slot forever. It reports cleanly in every other counter — this is the only
	// place it is visible, and it has happened.
	if report.DuplicatePercent >= 90 {
		fmt.Printf("[dc-rx] %s: %.0f%% of symbols reused an id — the stream is not being numbered\n",
			report.Source, report.DuplicatePercent)
	}
}

func dcEnvInt(name string, fallback int) int {
	raw := os.Getenv(name)
	if raw == "" {
		return fallback
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value < 0 {
		// REFUSED, NOT CLAMPED — the rule every RDEV_LLV_* variable follows. A typo that silently
		// became 0 would report an unprotected run as evidence about a protected one.
		panic(fmt.Sprintf("%s: expected a non-negative integer, got %q", name, raw))
	}
	return value
}

// setDelivery routes one slot. Returns whether the DataChannel is in force afterwards, which is what
// the caller reports as `activeDelivery` — the value the host DID, never the one it was asked for.
func (delivery *dcDelivery) setDelivery(slot int, useDC bool, sourceID string) bool {
	delivery.mutex.Lock()
	defer delivery.mutex.Unlock()
	if !useDC {
		delivery.retire(slot)
		return false
	}
	if delivery.streams[slot] != nil {
		return true
	}
	index := delivery.nextSourceIndex
	delivery.nextSourceIndex++
	delivery.streams[slot] = newDCVideoStream(index,
		dcEnvInt("RDEV_DC_WINDOW", dcDefaultWindowLen),
		dcEnvInt("RDEV_DC_REPAIR", dcDefaultRepairPerFrame),
		dcEnvInt("RDEV_DC_REPAIR_KEY", dcDefaultRepairPerKeyframe))
	if sourceID != "" {
		delivery.names[index] = sourceID
	}
	delivery.mutex.Unlock()
	delivery.announce()
	delivery.mutex.Lock()
	return true
}

// announce publishes the whole index -> source table on the feedback channel.
//
// THE WHOLE TABLE, AND REPLAYED ON OPEN, because routing happens BEFORE SCTP is up. The eager track
// is routed during session assembly, so a send at that moment is silently dropped for a channel that
// is not open yet — measured as 1,179 symbols arriving, decoding perfectly, and being discarded
// because nothing had told the client which source they belonged to.
//
// view-set carries the same mapping and stays authoritative for the real path; this is what makes the
// headless path bindable at all, and it removes the startup race everywhere else.
func (delivery *dcDelivery) announce() {
	delivery.mutex.Lock()
	feedback := delivery.feedback
	table := make(map[string]any, len(delivery.names))
	for index, name := range delivery.names {
		table[fmt.Sprint(index)] = name
	}
	delivery.mutex.Unlock()
	if feedback == nil || len(table) == 0 || feedback.ReadyState() != webrtc.DataChannelStateOpen {
		return
	}
	if payload, err := json.Marshal(map[string]any{"t": "dc-map", "sources": table}); err == nil {
		_ = feedback.Send(payload)
	}
}

func (delivery *dcDelivery) deliversOverDC(slot int) bool {
	delivery.mutex.Lock()
	defer delivery.mutex.Unlock()
	return delivery.streams[slot] != nil
}

// sourceIndexFor is what the caller reports to the client as `dcIndex`, so the client can bind an
// index to a source id.
//
// -1 RATHER THAN 0 FOR AN UNROUTED SLOT. Zero is a valid index, so answering it would bind a
// client's symbols to a source that is not being delivered over the channel at all.
func (delivery *dcDelivery) sourceIndexFor(slot int) int {
	delivery.mutex.Lock()
	defer delivery.mutex.Unlock()
	if stream := delivery.streams[slot]; stream != nil {
		return int(stream.sourceIndex)
	}
	return -1
}

// setHidden pauses or resumes emission for every routed source at once. SESSION-SCOPED, like the
// RTP path's visibility pause: it is a property of the CLIENT, not of any one window.
func (delivery *dcDelivery) setHidden(hidden bool) {
	if delivery != nil {
		delivery.hidden.Store(hidden)
	}
}

func (delivery *dcDelivery) release(slot int) {
	delivery.mutex.Lock()
	defer delivery.mutex.Unlock()
	delivery.retire(slot)
}

// retire drops a slot's stream AND the name of the index it held. CALL WITH THE MUTEX HELD.
//
// THE NAME MUST GO WITH THE STREAM. The index itself is never reused — that is deliberate, and it is
// what stops a late symbol from a retired source decoding into its replacement — but leaving its NAME
// behind grows every later announcement without bound. Measured after three resubscribes of one
// window: `names=map[0:win:127 1:win:127 2:win:127 3:win:127]`, three of them naming a stream that no
// longer existed, which makes the report unreadable exactly when it is being read to diagnose a
// routing failure.
func (delivery *dcDelivery) retire(slot int) {
	if stream := delivery.streams[slot]; stream != nil {
		delete(delivery.names, stream.sourceIndex)
	}
	delete(delivery.streams, slot)
}

// bumpAll marks a discontinuity on every live source — a peer rebuild.
func (delivery *dcDelivery) bumpAll() {
	delivery.mutex.Lock()
	defer delivery.mutex.Unlock()
	for _, stream := range delivery.streams {
		stream.bumpGeneration()
	}
}

// bump marks a discontinuity on one source — a codec change or encoder rebuild.
func (delivery *dcDelivery) bump(slot int) {
	delivery.mutex.Lock()
	defer delivery.mutex.Unlock()
	if stream := delivery.streams[slot]; stream != nil {
		stream.bumpGeneration()
	}
}

// write emits one access unit as symbols. Returns false when this slot is not delivered over the
// channel, which tells the caller to packetise it as RTP instead.
//
// THE RETURN VALUE REPORTS ROUTING, NOT CHANNEL HEALTH. A routed slot answers true even when the
// channel is closed, because answering false would silently duplicate the frame onto BOTH paths for
// as long as the channel was down.
func (delivery *dcDelivery) write(
	slot int, payload []byte, ptsNanoseconds int64, keyframe bool, payloadType uint8,
) bool {
	delivery.mutex.Lock()
	stream := delivery.streams[slot]
	if stream == nil {
		delivery.mutex.Unlock()
		return false
	}
	// HIDDEN RETURNS TRUE — routed, but silent. Returning false would fall this frame back to RTP
	// and un-pause the very stream the pause exists to stop.
	//
	// AND IT RETURNS BEFORE packetsFor, so the ESI space does not advance. A hidden source that kept
	// numbering would leave the client a gap it can never fill, waiting forever for symbols that were
	// never sent — indistinguishable from heavy loss, and permanent.
	if delivery.hidden.Load() {
		delivery.mutex.Unlock()
		delivery.hiddenAU.Add(1)
		return true
	}
	// THE SAME DEPENDENCY THE RTP PATH DESCRIBES, from the same function — `WriteVideo` builds this
	// for its descriptor, and building it separately here would be two definitions of one truth.
	packets := stream.packetsFor(payload, ptsNanoseconds, keyframe, payloadType,
		l1t1Dependency(keyframe).DependsOnOffset())
	sourceCount := 0
	for _, packet := range packets {
		if packet[5] == dcKindSource {
			sourceCount++
		}
	}
	delivery.mutex.Unlock()

	// REFUSE THE WHOLE FRAME WHILE THE QUEUE IS DEEP. Checked before a single byte is handed over,
	// because handing over is irreversible.
	if delivery.video != nil {
		depth := delivery.video.BufferedAmount()
		delivery.observeBuffered(depth, &delivery.sendBufferedMax)
		if !delivery.admitFrame(depth, len(packets)) {
			return true
		}
	}

	delivery.sourceSym.Add(uint64(sourceCount))
	delivery.repairSym.Add(uint64(len(packets) - sourceCount))
	for _, packet := range packets {
		// TEST-ONLY SEEDED LOSS. Zero by default, so the shipped path has one comparison per symbol
		// and nothing else. It exists because a gate on a clean loopback link cannot tell a working
		// code from a dead one: zero repair packets used is the CORRECT reading when nothing was lost,
		// which is the same reason gate-flexfec-under-loss.sh seeds loss on the RTP side.
		if delivery.lossBasisPoints > 0 {
			delivery.lossMutex.Lock()
			drop := delivery.lossRNG.Intn(10_000) < delivery.lossBasisPoints
			delivery.lossMutex.Unlock()
			if drop {
				delivery.seededLoss.Add(1)
				continue
			}
		}
		if delivery.video == nil || delivery.video.ReadyState() != webrtc.DataChannelStateOpen {
			delivery.notOpen.Add(1)
			continue
		}
		if err := delivery.video.Send(packet); err != nil {
			delivery.failed.Add(1)
			continue
		}
		delivery.sent.Add(1)
		delivery.sentBytes.Add(uint64(len(packet)))
		if packet[5] == dcKindRepair {
			delivery.repairBytes.Add(uint64(len(packet)))
		}
		delivery.observeBuffered(delivery.video.BufferedAmount(), &delivery.sendBufferedMax)
	}
	return true
}

// admitFrame decides whether a frame may be handed to SCTP at the current send-queue depth, and
// records it when it may not. Returns false when the frame is refused.
//
// A METHOD RATHER THAN AN INLINE CHECK so a test can drive the REAL decision. The first version of
// this test asserted against a copy of the logic living in the test file, and mutating the production
// branch away left it green — which is the failure this project names outright: a check that has to
// replicate the fix to test it proves nothing.
func (delivery *dcDelivery) admitFrame(depth uint64, symbols int) bool {
	refuse := func() bool {
		delivery.sheddedFrames.Add(1)
		delivery.sheddedSymbols.Add(uint64(symbols))
		return false
	}
	if delivery.shedding.Load() {
		// HYSTERESIS: shedding ends only once the queue is genuinely clear. A single threshold at the
		// drain rate oscillates — one frame in, one refused, forever — and never actually drains.
		if depth > dcSendLowWaterBytes {
			return refuse()
		}
		delivery.shedding.Store(false)
		return true
	}
	if depth >= dcSendHighWaterBytes {
		delivery.shedding.Store(true)
		return refuse()
	}
	return true
}

// setRepairRateFor points a source's stream at a new redundancy rate.
//
// BY SOURCE NAME, because that is what the receiver reports. The index it would otherwise be keyed by
// is retired and reissued across a re-route, and a rate applied to a stale one would be applied to
// nothing at all — silently, which is how a controller comes to look inert.
func (delivery *dcDelivery) setRepairRateFor(source string, rate float64) {
	delivery.mutex.Lock()
	defer delivery.mutex.Unlock()
	for index, name := range delivery.names {
		if name != source {
			continue
		}
		for _, stream := range delivery.streams {
			if stream.sourceIndex == index {
				stream.setRepairRate(rate)
			}
		}
	}
}

// retransmit answers a receiver's request for symbols it never got.
//
// THE REQUEST IS BOUNDED HERE, NOT TRUSTED. A receiver asking for thousands of symbols — through a
// bug, or because it fell far behind — would otherwise turn one message into a flood on the same
// channel that is already struggling, which is the opposite of a repair. Anything past the cap is
// dropped silently: a receiver that far behind needs a keyframe, not a backlog.
func (delivery *dcDelivery) retransmit(index uint16, esis []uint32) {
	if len(esis) == 0 {
		return
	}
	if len(esis) > dcMaxNackedSymbols {
		esis = esis[:dcMaxNackedSymbols]
	}
	delivery.mutex.Lock()
	var stream *dcVideoStream
	for _, candidate := range delivery.streams {
		if candidate.sourceIndex == index {
			stream = candidate
			break
		}
	}
	var packets [][]byte
	var missing int
	if stream != nil {
		packets, missing = stream.resend(esis)
	}
	delivery.mutex.Unlock()
	if stream == nil {
		return
	}
	delivery.nackedSymbols.Add(uint64(len(esis)))
	delivery.nackMisses.Add(uint64(missing))
	for _, packet := range packets {
		// STRAIGHT OUT, bypassing the seeded-loss injector: this path exists to answer a loss, and
		// dropping the answer would make the gate measure the injector rather than the mechanism.
		if delivery.video == nil || delivery.video.ReadyState() != webrtc.DataChannelStateOpen {
			delivery.notOpen.Add(1)
			continue
		}
		if err := delivery.video.Send(packet); err != nil {
			delivery.failed.Add(1)
			continue
		}
		delivery.sent.Add(1)
		delivery.sentBytes.Add(uint64(len(packet)))
		delivery.retransmitted.Add(1)
		// WHAT THIS ANSWER IS QUEUED BEHIND. The receiver measured its retransmissions arriving 15-21
		// FRAMES late — 250-350ms — against a window that waits four. If that delay is backlog rather
		// than distance, the answer is sitting behind everything already in the send buffer, and the
		// fix is congestion control rather than abandoning ARQ. The two look identical from the
		// receiving end.
		delivery.observeBuffered(delivery.video.BufferedAmount(), &delivery.rtxBufferedMax)
	}
}

/// The most symbols one request may ask for. A receiver needing more than this is not behind, it is
/// lost, and the answer to that is a keyframe.
const dcMaxNackedSymbols = 64

// observeBuffered keeps the high-water mark of a send-buffer depth. A MAXIMUM rather than an
// average: a backlog that forms and drains between two reports is exactly the event of interest, and
// averaging it away is how a congested link reads as a healthy one.
func (delivery *dcDelivery) observeBuffered(depth uint64, into *atomic.Uint64) {
	for {
		current := into.Load()
		if depth <= current || into.CompareAndSwap(current, depth) {
			return
		}
	}
}

// routedSlots reports how many slots are delivered over the channel, so a reporter can stay silent
// when there is nothing to say rather than printing zeroes that read as a fault.
func (delivery *dcDelivery) routedSlots() int {
	delivery.mutex.Lock()
	defer delivery.mutex.Unlock()
	return len(delivery.streams)
}

// report prints one window of counters.
//
// `src=0` WHILE A SOURCE IS ROUTED HERE IS THE FAILURE THIS EXISTS TO MAKE VISIBLE. Both faults
// found while prototyping this transport — colliding symbol ids, and an instrument left running on
// a control arm — reported cleanly while delivering nothing.
func (delivery *dcDelivery) report() string {
	if delivery == nil {
		return ""
	}
	source, repairs := delivery.sourceSym.Load(), delivery.repairSym.Load()
	overhead := 0.0
	if source > 0 {
		overhead = 100 * float64(repairs) / float64(source)
	}
	delivery.mutex.Lock()
	names := fmt.Sprint(delivery.names)
	delivery.mutex.Unlock()
	return fmt.Sprintf("[dc] routed=%d names=%s sent=%d failed=%d notOpen=%d · src=%d repair=%d (%.1f%% overhead)",
		delivery.routedSlots(), names, delivery.sent.Load(), delivery.failed.Load(),
		delivery.notOpen.Load(), source, repairs, overhead) +
		fmt.Sprintf(" · %s wire (repair %s)",
			humanBytes(delivery.sentBytes.Load()), humanBytes(delivery.repairBytes.Load())) +
		fmt.Sprintf(" · buffered max %s (rtx behind %s)",
			humanBytes(delivery.sendBufferedMax.Swap(0)), humanBytes(delivery.rtxBufferedMax.Swap(0))) +
		// PRINTED EVEN WHEN ZERO. A shed frame is the difference between a degraded picture and a dead
		// connection, so its absence has to be as legible as its presence.
		fmt.Sprintf(" · shed %d frames/%d symbols", delivery.sheddedFrames.Swap(0), delivery.sheddedSymbols.Swap(0)) +
		fmt.Sprintf(" · rtx %d/%d asked (%d too old)",
			delivery.retransmitted.Load(), delivery.nackedSymbols.Load(), delivery.nackMisses.Load()) +
		fmt.Sprintf(" seededLoss=%d", delivery.seededLoss.Load())
}

// humanBytes renders a cumulative byte count compactly. The report is read beside `[encode]`, whose
// numbers are kbit/s, so a raw byte total is the hardest of the two to compare against the other.
func humanBytes(n uint64) string {
	switch {
	case n >= 1<<30:
		return fmt.Sprintf("%.1fGB", float64(n)/(1<<30))
	case n >= 1<<20:
		return fmt.Sprintf("%.1fMB", float64(n)/(1<<20))
	case n >= 1<<10:
		return fmt.Sprintf("%.1fkB", float64(n)/(1<<10))
	default:
		return fmt.Sprintf("%dB", n)
	}
}
