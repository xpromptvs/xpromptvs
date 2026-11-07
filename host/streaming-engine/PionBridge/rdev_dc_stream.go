package main

import (
	"encoding/binary"
	"math"
)

// One source's DataChannel video stream: its ESI space, its generation, its sliding-window encoder
// and its repair policy.
//
// PER SOURCE, NOT PER SESSION, even though every source shares one channel. Pooling repair across
// sources would mean repairing source A required source B's symbols, so an unsubscribed or paused
// source would break another's recovery.
//
// Header layout, little-endian. Both kinds are 36 bytes so the payload offset is constant.
//
//	COMMON  u32 magic 'RDVS' · u8 version · u8 kind · u16 symbolBytes
//	SOURCE  u32 esi · u32 frameSeq · u32 rtpTimestamp · u16 fragIndex · u16 fragCount ·
//	        u32 frameBytes · u8 keyframe · u8 payloadType · u16 sourceIndex · u8 generation · u8[3] ·
//	        u32 frameHash · u8 dependsOnOffset (in byte 33)
//	REPAIR  u32 firstESI · u16 windowLen · u16 pad · u32 seed · u16 sourceIndex · u8 generation ·
//	        u8[13] · u32 unused
//
// The TypeScript twin is web/src/lib/dc-wire.ts, pinned by hand-built headers in
// web/test/dc-wire.test.ts. A VERSION MISMATCH IS REFUSED THERE RATHER THAN PARSED: two builds
// disagreeing about a fixed-size header read every field at the wrong offset and produce entirely
// plausible garbage, which is a picture that is wrong rather than an error that says so.
// A FRAME CARRIES A HASH OF ITSELF, and the receiver throws away anything that does not match.
//
// WHY: the sliding-window code SOLVES for a lost symbol, and a solve against a stale or wrong
// equation does not fail — it produces a symbol of exactly the right length full of plausible
// garbage, which is handed to VideoDecoder as though it were video. Reported from a live session as
// damaged pictures, repeatedly, in the run-up to the tab locking up. Nothing between the wire and the
// codec could have stopped it: every field the receiver checks describes the framing, not the
// content.
//
// FNV-1a over the assembled access unit. Not a cryptographic hash and not trying to be — the threat
// is a decoder fed nonsense, not a forger — and 32 bits over a few kilobytes leaves a chance of a
// silent pass around one in four billion per damaged frame.
const (
	dcHeaderBytes = 40
	dcSymbolBytes = 1_200
	dcMagic       = 0x53564452 // "RDVS" little-endian
	dcVersion     = 7
	dcKindSource  = 0
	dcKindRepair  = 1
	// 90 kHz / 60 fps. The step used when a frame reports no capture time.
	dcClockStep = 1_500
)

type dcVideoStream struct {
	sourceIndex       uint16
	generation        uint8
	windowLen         int
	repairPerFrame    int
	repairPerKeyframe int
	/// Repair symbols per source symbol. Adaptive: see `repairRateForLoss`.
	repairRate   float64
	repairCredit float64

	encoder  *rlcEncoder
	nextESI  uint32
	frameSeq uint32

	// The media clock, ANCHORED. `epochNanos` is the first frame's capture instant and every later
	// timestamp is measured from it, so the rounding error stays at one tick for the life of the
	// stream instead of accumulating. `stepped` is the fallback clock for a source that reports no
	// capture time at all.
	epochNanos int64
	hasEpoch   bool
	stepped    uint32

	// RECENTLY SENT SOURCE SYMBOLS, so a receiver can ask for one again.
	//
	// WHY ARQ AND NOT MORE FEC. Measured on a relayed WAN path: 26.9% of the wire spent on repair
	// recovered about 9% of what was lost, because real loss there is BURSTY — a burst taking several
	// symbols from one window exceeds the rank available to solve it, and adding redundancy makes the
	// burst likelier rather than the recovery better. A retransmission has none of that problem, and
	// the buffer to hide one is already being held: the client's adaptive margin measured 72ms against
	// a 25ms RTT, so a request and its answer fit inside the latency already paid for.
	//
	// ONLY SOURCE SYMBOLS ARE KEPT. A repair symbol is a combination over a window that has since
	// moved on, so resending one is worth nothing to a decoder that has already pruned its terms.
	history      map[uint32][]byte
	historyOrder []uint32
}

/// How many source symbols stay resendable. At 60fps and a few symbols a frame this is a couple of
/// seconds of history — far more than the round trip needs, and bounded so a stalled receiver cannot
/// make the host grow without limit.
const dcHistoryLen = 512

func newDCVideoStream(sourceIndex uint16, windowLen, repairPerFrame, repairPerKeyframe int) *dcVideoStream {
	stream := &dcVideoStream{
		sourceIndex:       sourceIndex,
		windowLen:         windowLen,
		repairPerFrame:    repairPerFrame,
		repairPerKeyframe: repairPerKeyframe,
		history:           make(map[uint32][]byte, dcHistoryLen),
	}
	stream.resetCoding()
	stream.repairRate = repairRateFloor
	return stream
}

// setRepairRate changes how much redundancy this stream spends, as a fraction of its source symbols.
//
// THE CEILING IS NOT ENFORCED HERE. This is the mechanism; the bound on how much redundancy a link
// deserves is a policy, and it lives in `repairRateForLoss` where the reasoning for it is. Clamping
// in both places means a caller that deliberately asks for more — a test, or a future controller
// with a different rule — is silently overruled by a limit belonging to a decision it is not making.
func (stream *dcVideoStream) setRepairRate(rate float64) {
	if rate < 0 {
		rate = 0
	}
	stream.repairRate = rate
}

/// The redundancy a link deserves, from the frame loss its receiver reports.
///
/// FIVE PERCENT WHEN NOTHING IS BEING LOST. Redundancy is not free — it is bytes on the same link
/// that is dropping things — and a local link that loses nothing should pay almost nothing. The floor
/// is not zero because loss has to be OBSERVED before it can be answered, and a stream with no
/// protection at all learns about a bad link one lost frame at a time.
///
/// CAPPED, because past a point redundancy stops being the answer. A link losing a tenth of its
/// symbols cannot be repaired into a good one by spending half the wire on parity; that is a link
/// that needs a lower bitrate or a different path, and spending more only makes the congestion worse.
func repairRateForLoss(lossPercent float64) float64 {
	// Roughly twenty times the loss: a percent of loss buys a fifth of the wire in protection, which
	// is what a sliding window needs to cover a burst of that rate rather than an isolated drop.
	rate := repairRateFloor + lossPercent*0.2
	if rate > repairRateCeiling {
		rate = repairRateCeiling
	}
	return rate
}

const (
	repairRateFloor   = 0.05
	repairRateCeiling = 0.50
)

// resetCoding starts a fresh ESI space and a fresh window. The seed is derived from the generation so
// two generations never reuse a coefficient sequence.
func (stream *dcVideoStream) resetCoding() {
	stream.nextESI = 0
	stream.frameSeq = 0
	stream.hasEpoch = false
	stream.stepped = 0
	// THE HISTORY GOES WITH THE ESI SPACE. Numbering restarts here, so a retained packet would answer
	// a request for esi 5 with the PREVIOUS generation's symbol — the exact ambiguity the generation
	// byte exists to prevent, reintroduced through the back door.
	stream.history = make(map[uint32][]byte, dcHistoryLen)
	stream.historyOrder = nil
	if stream.windowLen > 0 {
		// Parenthesised deliberately: `|` binds looser than `+`, so the intent is easy to misread.
		stream.encoder = newRLCEncoder(dcSymbolBytes, stream.windowLen,
			0x5eed0000|(uint32(stream.generation)+1))
	} else {
		stream.encoder = nil
	}
}

// bumpGeneration marks a discontinuity: a codec change, an encoder rebuild or a peer rebuild.
func (stream *dcVideoStream) bumpGeneration() {
	stream.generation++
	stream.resetCoding()
}

// mediaTimestamp converts a capture instant to the 90 kHz media clock the client's decoder paces on.
//
// ANCHORED TO THE FIRST FRAME, NOT SUMMED. A per-frame delta rounds the same way every time, so the
// residual never cancels and the clock drifts — measured at +82 ticks over 300 frames when the RTP
// path did it that way. Anchoring holds the error at one tick for the life of the stream.
//
// ptsNanoseconds <= 0 MEANS ABSENT, and keeps the fixed 60 fps step rather than collapsing every
// frame onto one instant. That collapse is not hypothetical: an earlier draft of this work passed a
// constant timestamp, which would have left the client's pacer with no media clock at all.
//
// The multiply is by 9/100000 rather than 90000/1e9 so it stays in int64 for any session length this
// will ever see.
func (stream *dcVideoStream) mediaTimestamp(ptsNanoseconds int64) uint32 {
	if ptsNanoseconds <= 0 {
		timestamp := stream.stepped
		stream.stepped += dcClockStep
		return timestamp
	}
	if !stream.hasEpoch {
		stream.epochNanos = ptsNanoseconds
		stream.hasEpoch = true
	}
	elapsed := ptsNanoseconds - stream.epochNanos
	if elapsed < 0 {
		elapsed = 0
	}
	return uint32(elapsed * 9 / 100_000)
}

// packetsFor fragments one access unit into source symbols and appends this frame's repair symbols.
//
// REPAIR COMES AFTER THE FRAME'S SOURCE SYMBOLS, which is what makes recovery free: a repair emitted
// here already covers this frame, so a single loss in it is repairable immediately, and the next
// frame's repair covers it again so a second loss costs one frame rather than everything until the
// next IDR.
func (stream *dcVideoStream) packetsFor(
	payload []byte, ptsNanoseconds int64, keyframe bool, payloadType uint8, dependsOnOffset uint8,
) [][]byte {
	count := (len(payload) + dcSymbolBytes - 1) / dcSymbolBytes
	if count == 0 {
		count = 1
	}
	frameSeq := stream.frameSeq
	stream.frameSeq++
	// COMPUTED ONCE OVER THE WHOLE ACCESS UNIT, then repeated in every one of its symbols — like
	// `frameBytes`, so a frame is checkable from whichever symbols happen to survive.
	frameHash := fnv1a(payload)
	rtpTimestamp := stream.mediaTimestamp(ptsNanoseconds)
	// THE BUDGET IS DECIDED BEFORE THE FRAME IS WRITTEN, because the repairs have to be interleaved
	// WITH the source symbols rather than appended after them. See the emission below.
	stream.repairCredit += float64(count) * stream.repairRate
	repair := int(stream.repairCredit)
	stream.repairCredit -= float64(repair)
	if keyframe {
		if minimum := stream.keyframeRepair(count); repair < minimum {
			repair = minimum
		}
	}
	emitted := 0

	packets := make([][]byte, 0, count+repair)

	for index := 0; index < count; index++ {
		start := index * dcSymbolBytes
		end := start + dcSymbolBytes
		if end > len(payload) {
			end = len(payload)
		}
		// PADDED FOR THE ALGEBRA, NOT FOR THE WIRE — v5, and the distinction is the whole point.
		//
		// A repair symbol is a linear combination over the window, so the linear system requires
		// equal-length symbols. `addSource` is what supplies that width — it copies into a fresh
		// `symbolBytes` buffer, so a short symbol arrives zero-padded — and the receiver zero-extends
		// the same way before solving. Neither end needs the padding to travel.
		//
		// Sending it cost most of rdev's uplink on a quiet window. Measured over a relayed WAN link on
		// a near-static source: ~27-byte frames going out as 1236-byte messages, about 1.18 Mbit/s of
		// wire for 13 kbit/s of video. Repair symbols are genuinely dense and stay full length.
		esi := stream.nextESI
		stream.nextESI++
		if stream.encoder != nil {
			stream.encoder.addSource(payload[start:end], esi)
		}
		packet := make([]byte, dcHeaderBytes+(end-start))
		stream.writeCommon(packet, dcKindSource)
		binary.LittleEndian.PutUint32(packet[8:], esi)
		binary.LittleEndian.PutUint32(packet[12:], frameSeq)
		binary.LittleEndian.PutUint32(packet[16:], rtpTimestamp)
		binary.LittleEndian.PutUint16(packet[20:], uint16(index))
		binary.LittleEndian.PutUint16(packet[22:], uint16(count))
		binary.LittleEndian.PutUint32(packet[24:], uint32(len(payload)))
		if keyframe {
			packet[28] = 1
		}
		packet[29] = payloadType
		binary.LittleEndian.PutUint32(packet[36:], frameHash)
		// HOW FAR BACK THIS FRAME'S REFERENCE IS, so the receiver can decide on ARRIVAL whether it is
		// decodable instead of inferring it from a hole and a timer. Zero means it references nothing.
		packet[33] = dependsOnOffset
		copy(packet[dcHeaderBytes:], payload[start:end])
		stream.remember(esi, packet)
		packets = append(packets, packet)

		// REPAIRS ARE SPREAD THROUGH THE FRAME, NOT APPENDED AFTER IT — and for any frame longer than
		// the coding window this is the difference between protection and none at all.
		//
		// `buildRepair` combines the encoder's CURRENT window: the last `windowLen` symbols, 16 by
		// default. Emitting every repair after the final source symbol therefore protects only the
		// final 16. Measured against a real keyframe of 39 symbols (45.7 kB, `max packets=39` in the
		// host's own [frames] line), the first 23 symbols were covered by nothing — not by that
		// frame's repairs, which had already slid past them, and not by any later frame's, whose
		// window has moved on. No repair COUNT can fix that; the emission has to be interleaved.
		//
		// Placed after `addSource` for this index so the symbol just written is inside the window the
		// repair is built over. Distributing by `repair * (index+1) / count` puts them evenly across
		// the frame and reduces to "one at the end" for a single-repair frame, which is what small
		// frames did before.
		for due := repair * (index + 1) / count; emitted < due && stream.encoder != nil; emitted++ {
			if p := stream.buildRepairPacket(); p != nil {
				packets = append(packets, p)
			}
		}
	}

	// ANY REMAINDER. Integer division in the interleave can leave the last repair unemitted when
	// `repair` does not divide `count`; a frame must not silently ship less protection than it was
	// budgeted.
	for ; emitted < repair && stream.encoder != nil; emitted++ {
		if p := stream.buildRepairPacket(); p != nil {
			packets = append(packets, p)
		}
	}
	return packets
}

/// One repair symbol over the encoder's CURRENT window, or nil when the window is empty.
func (stream *dcVideoStream) buildRepairPacket() []byte {
	body, firstESI, windowLen, seed := stream.encoder.buildRepair()
	if body == nil {
		return nil
	}
	packet := make([]byte, dcHeaderBytes+dcSymbolBytes)
	stream.writeCommon(packet, dcKindRepair)
	binary.LittleEndian.PutUint32(packet[8:], firstESI)
	binary.LittleEndian.PutUint16(packet[12:], uint16(windowLen))
	binary.LittleEndian.PutUint32(packet[16:], seed)
	copy(packet[dcHeaderBytes:], body)
	return packet
}

// A KEYFRAME IS PROTECTED AT A RATE, NOT A COUNT — and at the rate a delta frame reaches only at the
// worst loss the controller will ever measure.
//
// The old rule was a flat two symbols whatever the frame's size. Against a real keyframe of 39
// symbols that is 4.9% tolerance, while the delta frames around it — three symbols each — were
// getting the full adaptive rate. The one frame the entire recovery path depends on was the least
// protected thing on the wire, and the failure it produced is a stall, not a glitch: under an
// INFINITE GOP a keyframe is the only way the stream can restart, and rdev only asks for one when the
// receiver is ALREADY in trouble. So its redundancy must be sized for the condition it is sent in,
// not for the average.
//
// Observed as exactly that: a receiver stuck at frame 777 asking for keyframes it could never
// assemble, the host producing ten per window and suppressing dozens more against the 500ms debounce,
// while every delta frame around them arrived intact.
func (stream *dcVideoStream) keyframeRepair(count int) int {
	byRate := int(math.Ceil(float64(count) * dcKeyframeRepairRate))
	if byRate < stream.repairPerKeyframe {
		return stream.repairPerKeyframe
	}
	return byRate
}

func (stream *dcVideoStream) writeCommon(packet []byte, kind byte) {
	binary.LittleEndian.PutUint32(packet[0:], dcMagic)
	packet[4] = dcVersion
	packet[5] = kind
	binary.LittleEndian.PutUint16(packet[6:], uint16(dcSymbolBytes))
	binary.LittleEndian.PutUint16(packet[30:], stream.sourceIndex)
	packet[32] = stream.generation
}

// remember keeps a source packet resendable, evicting the oldest once the ring is full.
func (stream *dcVideoStream) remember(esi uint32, packet []byte) {
	stream.history[esi] = packet
	stream.historyOrder = append(stream.historyOrder, esi)
	if len(stream.historyOrder) > dcHistoryLen {
		delete(stream.history, stream.historyOrder[0])
		stream.historyOrder = stream.historyOrder[1:]
	}
}

// resend returns the packets for the requested ESIs that are still in history.
//
// SILENTLY SHORT IS CORRECT. A receiver may ask for something evicted, or for a symbol from a
// previous generation; there is nothing useful to say about either, and answering with an error
// would only tell it something it cannot act on. The COUNT of unanswerable requests is worth having,
// which is why the caller counts what it did not find.
func (stream *dcVideoStream) resend(esis []uint32) (found [][]byte, missing int) {
	for _, esi := range esis {
		if packet, ok := stream.history[esi]; ok {
			found = append(found, packet)
		} else {
			missing++
		}
	}
	return found, missing
}

// fnv1a is the 32-bit FNV-1a hash. Chosen for having no table, no allocation and no dependency: this
// runs on every frame on the send path, and its twin runs on every frame on the receive path.
func fnv1a(data []byte) uint32 {
	hash := uint32(2166136261)
	for _, b := range data {
		hash ^= uint32(b)
		hash *= 16777619
	}
	return hash
}
