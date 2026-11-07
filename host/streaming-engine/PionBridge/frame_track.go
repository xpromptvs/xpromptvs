package main

import (
	"errors"
	"fmt"
	"math"
	"strings"
	"sync"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/rtcp"
	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"
)

const (
	maximumRTPBytes = 1_200
	rtpClockStep    = uint32(1_500)

	// rtpClockRate is the video clock every profile in the table registers at.
	rtpClockRate = uint64(90_000)

	// fixedStepNanos is rtpClockStep expressed as time: 1500 ticks at 90 kHz. It keeps the
	// presentation anchor honest across a frame that carries no timestamp, so the frame after one
	// does not count that interval twice.
	fixedStepNanos = uint64(16_666_667)

	// maximumPresentationGapNanos bounds a single advance. An IDLE GAP IS CARRIED HONESTLY AND THAT
	// IS THE WHOLE POINT — a window nobody touches produces no frames, and a receiver told that
	// nothing happened for two seconds schedules the next frame correctly. This only refuses a jump
	// so large it is a broken clock rather than a quiet window, because one bad value would
	// otherwise wrap the 32-bit timestamp and desynchronise the stream permanently.
	maximumPresentationGapNanos = uint64(10_000_000_000)
)

var errFrameTrack = errors.New("frame track failed")

type AV1ScalabilityMode uint8

const (
	AV1ScalabilityL1T1 AV1ScalabilityMode = 1
	AV1ScalabilityL1T2 AV1ScalabilityMode = 2
	AV1ScalabilityL1T3 AV1ScalabilityMode = 3
)

type AV1Dependency struct {
	Mode       AV1ScalabilityMode
	TemporalID uint8
	TemplateID uint8
}

func l1t1Dependency(keyframe bool) AV1Dependency {
	templateID := uint8(1)
	if keyframe {
		templateID = 0
	}
	return AV1Dependency{Mode: AV1ScalabilityL1T1, TemplateID: templateID}
}

// DependsOnOffset reports how many frames back this frame's reference is, in the stream's own frame
// numbering. Zero means it references nothing — a keyframe.
//
// THIS IS WHAT A RECEIVER NEEDS AND THE DataChannel WAS NOT CARRYING. Without it the client can only
// notice a hole in the sequence and stop everything until a keyframe, which is correct for a linear
// chain and wrong for anything else — and it was correct only because the write path hardcodes L1T1.
// With the offset, a frame's decodability is a question about THAT frame, answerable the moment it
// arrives, rather than an inference from a gap and a timer.
//
// The offsets follow the templates the encoder is configured with in CAOMBridge.c: in a temporal
// hierarchy a base-layer frame skips the upper-layer frames between it and its reference, which is
// exactly why losing an upper-layer frame costs nothing and losing a base-layer frame costs
// everything.
func (dependency AV1Dependency) DependsOnOffset() uint8 {
	if dependency.TemplateID == 0 {
		return 0 // a keyframe starts the chain
	}
	switch dependency.Mode {
	case AV1ScalabilityL1T1:
		return 1
	case AV1ScalabilityL1T2:
		if dependency.TemplateID == 1 {
			return 2 // base layer, skipping the upper-layer frame between
		}
		return 1
	case AV1ScalabilityL1T3:
		switch dependency.TemplateID {
		case 1:
			return 4 // base layer, skipping the two upper-layer frames between
		case 2:
			return 2 // middle layer, referencing the previous base
		default:
			return 1
		}
	default:
		// A STRUCTURE THIS DOES NOT UNDERSTAND IS TREATED AS A CHAIN. Reporting "depends on nothing"
		// would tell the receiver it is safe to decode, which is the one answer that yields a corrupt
		// picture rather than a brief freeze.
		return 1
	}
}

func (dependency AV1Dependency) Validate(keyframe bool) error {
	var expectedTemporalID uint8
	validTemplate := false
	switch dependency.Mode {
	case AV1ScalabilityL1T1:
		validTemplate = dependency.TemplateID <= 1
	case AV1ScalabilityL1T2:
		validTemplate = dependency.TemplateID <= 2
		if dependency.TemplateID == 2 {
			expectedTemporalID = 1
		}
	case AV1ScalabilityL1T3:
		validTemplate = dependency.TemplateID <= 4
		switch dependency.TemplateID {
		case 2:
			expectedTemporalID = 1
		case 3, 4:
			expectedTemporalID = 2
		}
	}
	if !validTemplate {
		return fmt.Errorf(
			"%w: invalid AV1 dependency mode=%d template=%d",
			errFrameTrack, dependency.Mode, dependency.TemplateID,
		)
	}
	if dependency.TemporalID != expectedTemporalID {
		return fmt.Errorf(
			"%w: invalid AV1 temporal ID mode=%d template=%d temporal=%d",
			errFrameTrack, dependency.Mode, dependency.TemplateID, dependency.TemporalID,
		)
	}
	if keyframe != (dependency.TemplateID == 0) {
		return fmt.Errorf(
			"%w: AV1 keyframe/template mismatch keyframe=%t template=%d",
			errFrameTrack, keyframe, dependency.TemplateID,
		)
	}
	return nil
}

type OutboundFrame struct {
	Started             *bool // Frame clock accepted this attempt, including a later partial send.
	Reference           *referenceFrameMetadata
	ReferenceResult     *referenceSendResult
	StreamID            uint64
	FrameID             uint64
	InputSequence       uint64
	HostProcessingNanos uint64
	EncodeNanos         uint64
	Keyframe            bool
	Dependency          AV1Dependency
	Data                []byte

	// PresentationNanos is when this frame was CAPTURED, on any monotonic nanosecond clock. It sets
	// the RTP timestamp, which is what a receiver schedules playout from.
	//
	// ZERO MEANS ABSENT, and absent keeps the old fixed 60 fps step. That is what leaves LLV's
	// answering path (SendVideo) byte-identical while rdev's own path (WriteVideo) tells the truth —
	// the two share this track and only one of them has a real timestamp to give.
	//
	// ONLY THE DIFFERENCES ARE USED, never the absolute value, so the epoch is free to be anything
	// (rdev passes DispatchTime uptime) and no clock domain has to be agreed across the ABI.
	PresentationNanos uint64
}

type frameTrackBinding struct {
	// profile is the codec this binding selected. Everything codec-specific below the bind reads
	// from it: the payloader, whether a dependency descriptor is emitted, and what the session
	// reports as the resolved codec.
	profile                         videoCodecProfile
	id                              string
	ssrc                            webrtc.SSRC
	payloadType                     webrtc.PayloadType
	metadataExtensionID             uint8
	playoutDelayExtensionID         uint8
	dependencyDescriptorExtensionID uint8
	sequence                        uint16
	writer                          webrtc.TrackLocalWriter
}

type FrameTrack struct {
	mutex    sync.Mutex
	id       string
	streamID string

	timestamp             uint32
	dependencyFrameNumber uint64
	referenceLedger       referenceFrameLedger
	// The timestamp is derived from an EPOCH plus total elapsed capture time, never by summing
	// per-frame rounded deltas. Summing is the obvious shape and it is wrong: a constant interval
	// rounds the same way every time, so the residual never cancels and the clock drifts anyway —
	// measured at +82 ticks over 300 frames, a bug of exactly the kind this replaces. Anchoring
	// holds the error at one tick for the life of the stream.
	//
	// presentationNanos is the previous frame's capture instant, kept for the gap clamp and the
	// monotonicity guard. hasPresentation says whether there is one yet; wroteAccessUnit says
	// whether any frame has gone out, which is what leaves the first timestamp untouched.
	baseTimestamp     uint32
	elapsedNanos      uint64
	presentationNanos uint64
	hasPresentation   bool
	wroteAccessUnit   bool
	// This track's playout-delay bounds, in the extension's 10 ms units. Both start from the
	// environment; the floor is settable per session. Guarded by mutex, which WriteAccessUnit
	// already holds where they are read.
	playoutDelayMinUnits uint16
	playoutDelayMaxUnits uint16
	// The ceiling this track was CONFIGURED with, kept so a raised ceiling can be undone. Without it
	// the raise below is one-way and "Auto" stops meaning what it meant a minute earlier.
	playoutDelayCeilingBaseUnits uint16
	bindings                     map[string]*frameTrackBinding
	onBound                      func()
	// codecPreference is this track's own preference order, or nil for rdev's global one. It exists
	// so a caller can pin a track's codec without changing what the session OFFERS — the offer
	// carries every registered codec regardless, and this only decides which of the survivors wins.
	codecPreference         []codecID
	onFrameStart            func(uint64, uint64) error
	onKeyframeRequest       func()
	onKeyframeSent          func(uint32, uint16)
	pliHandledByInterceptor bool
	firHandledByInterceptor bool
	trace                   *recoveryTraceRecorder
}

func NewFrameTrack(id, streamID string, traces ...*recoveryTraceRecorder) *FrameTrack {
	seed := uint64(time.Now().UnixNano())
	var trace *recoveryTraceRecorder
	if len(traces) != 0 {
		trace = traces[0]
	}
	return &FrameTrack{
		id: id, streamID: streamID, timestamp: uint32(seed),
		dependencyFrameNumber: uint64(uint16(seed)),
		bindings:              make(map[string]*frameTrackBinding), trace: trace,
		playoutDelayMinUnits:         defaultPlayoutDelayMinimumUnits(),
		playoutDelayMaxUnits:         playoutDelayCeilingUnits(),
		playoutDelayCeilingBaseUnits: playoutDelayCeilingUnits(),
	}
}

// SetPlayoutDelayMinimumMilliseconds sets the floor this track asks its receiver to hold.
//
// THE FLOOR FORCES; THE CEILING ONLY PERMITS. That asymmetry is the whole reason this is settable: a
// receiver that honours the sender's extension over its own jitterBufferTarget — WebKit does — cannot
// be made to buffer by any other means.
//
// IT IS UNCONDITIONAL, so treat a non-zero value as latency spent on purpose. Zero restores "play
// this out as soon as you can", which is the default and the project's whole point.
//
// A FLOOR CARRIES ITS OWN CEILING. A floor above the ceiling is a contradiction on the wire, and
// refusing it would make a client's control a silent no-op unless an operator had separately raised
// the ceiling by environment variable — the exact shape of trap this project keeps finding. The floor
// raises the ceiling to meet it instead; the ceiling only ever PERMITS, so widening it to satisfy an
// explicit request costs nothing on a link that does not use it. Out of the extension's 12-bit range
// is still refused, with the previous value standing.
func (track *FrameTrack) SetPlayoutDelayMinimumMilliseconds(milliseconds int) error {
	return track.SetPlayoutDelayBoundsMilliseconds(milliseconds, -1)
}

// SetPlayoutDelayBoundsMilliseconds sets BOTH bounds. `maximumMilliseconds < 0` means "the configured
// ceiling, raised to the floor if the floor is higher" — the behaviour every caller had before an
// explicit maximum existed. An explicit maximum below the floor is refused: that is a contradiction
// on the wire, not a clamp.
//
// WHY A CLIENT MAY SET THE MAXIMUM AT ALL. Measured 2026-09-04 on Chromium (docs/latency-campaign/
// 2026-09-04-report.md): with min 0 / max 500 the receiver adds its own jitter estimate on top of
// whatever floor it is given and renders through its two-refresh compositor path — glass-to-glass
// 57 ms on loopback. With min = max = 10 the render time is a fixed offset from capture, the
// low-latency compositor path engages, and the same stream reads 27 ms with every frame in phase
// (judder p95 0.8 ms, 60.0 fps). min 0 / max 10 or 20 engages the fast path but the receiver then
// drops or phase-flips frames; 20/20 loses the fast path. The window is the setting, not either bound.
// The client that measures the path decides; the engine only refuses what the field cannot carry.
func (track *FrameTrack) SetPlayoutDelayBoundsMilliseconds(minimumMilliseconds, maximumMilliseconds int) error {
	minUnits, ok := playoutDelayUnitsFromMilliseconds(minimumMilliseconds)
	if !ok {
		return fmt.Errorf("%w: playout-delay floor %dms is outside the extension's range",
			errFrameTrack, minimumMilliseconds)
	}
	explicitMax := maximumMilliseconds >= 0
	var maxUnits uint16
	if explicitMax {
		maxUnits, ok = playoutDelayUnitsFromMilliseconds(maximumMilliseconds)
		if !ok {
			return fmt.Errorf("%w: playout-delay ceiling %dms is outside the extension's range",
				errFrameTrack, maximumMilliseconds)
		}
		if maxUnits < minUnits {
			return fmt.Errorf("%w: playout-delay ceiling %dms is below the %dms floor",
				errFrameTrack, maximumMilliseconds, minimumMilliseconds)
		}
	}
	track.mutex.Lock()
	defer track.mutex.Unlock()
	track.playoutDelayMinUnits = minUnits
	if explicitMax {
		track.playoutDelayMaxUnits = maxUnits
		return nil
	}
	// THE RAISE MUST UNDO. The ceiling is always the configured one OR the floor, whichever is higher —
	// computed fresh rather than ratcheted, so lowering the floor back to zero restores the ceiling too.
	// Ratcheting made "Auto" a different setting after any excursion: a session that briefly held a
	// 100ms floor went on PERMITTING a 100ms receiver buffer forever, which on WebKit — the engine that
	// honours the sender's extension over its own jitterBufferTarget — really does change how much the
	// far side may hold, long after the user put the control back.
	track.playoutDelayMaxUnits = track.playoutDelayCeilingBaseUnits
	if track.playoutDelayMaxUnits < minUnits {
		track.playoutDelayMaxUnits = minUnits
	}
	return nil
}

// PlayoutDelayBoundsUnits reports the floor and ceiling this track currently STAMPS ON EVERY PACKET,
// in the extension's 10ms units.
//
// It exists so a log line can state what the wire carries rather than what was asked for. The two can
// differ — a floor raises the ceiling to meet it — and a report of "video is late after returning to
// Auto" could not be told apart from "the build predates the fix" without seeing the resolved pair.
func (track *FrameTrack) PlayoutDelayBoundsUnits() (minUnits uint16, maxUnits uint16) {
	track.mutex.Lock()
	defer track.mutex.Unlock()
	return track.playoutDelayMinUnits, track.playoutDelayMaxUnits
}

func (track *FrameTrack) Bind(context webrtc.TrackLocalContext) (webrtc.RTPCodecParameters, error) {
	track.mutex.Lock()

	// SELECT BY rdev's PREFERENCE from what was negotiated. The answer's own order is the
	// ANSWERER's preference and is deliberately not honoured: Chrome accepts AV1 and H.265 both,
	// and AV1 is measurably better per bit on the text and UI rdev actually streams. Registering in
	// preference order makes the OFFER honest about what rdev would rather send; this makes it true.
	var selected *webrtc.RTPCodecParameters
	var selectedProfile videoCodecProfile
	for _, profile := range preferredProfiles(track.codecPreference) {
		for _, candidate := range context.CodecParameters() {
			if strings.EqualFold(candidate.MimeType, profile.mimeType) && candidate.ClockRate == 90_000 {
				value := candidate
				selected = &value
				selectedProfile = profile
				break
			}
		}
		if selected != nil {
			break
		}
	}
	if selected == nil {
		track.mutex.Unlock()
		return webrtc.RTPCodecParameters{}, fmt.Errorf(
			"%w: none of rdev's codecs were negotiated", errFrameTrack)
	}
	metadataExtensionID := 0
	playoutDelayExtensionID := 0
	dependencyDescriptorExtensionID := 0
	for _, extension := range context.HeaderExtensions() {
		switch extension.URI {
		case frameMetadataURI:
			metadataExtensionID = extension.ID
		case playoutDelayURI:
			playoutDelayExtensionID = extension.ID
		case dependencyDescriptorURI:
			dependencyDescriptorExtensionID = extension.ID
		}
	}
	if metadataExtensionID < 0 || metadataExtensionID > math.MaxUint8 {
		track.mutex.Unlock()
		return webrtc.RTPCodecParameters{}, fmt.Errorf("%w: invalid metadata extension ID", errFrameTrack)
	}
	if playoutDelayExtensionID <= 0 || playoutDelayExtensionID > math.MaxUint8 {
		track.mutex.Unlock()
		return webrtc.RTPCodecParameters{}, fmt.Errorf("%w: playout-delay extension was not negotiated", errFrameTrack)
	}
	// REQUIRED ONLY BY THE CODECS THAT EMIT ONE. An H.264/H.265 browser negotiates no descriptor,
	// and demanding one here would refuse to bind before packetization was ever reached — the
	// failure would name a header extension while the cause is the codec.
	if selectedProfile.emitsDependencyDescriptor &&
		(dependencyDescriptorExtensionID <= 0 || dependencyDescriptorExtensionID > math.MaxUint8) {
		track.mutex.Unlock()
		return webrtc.RTPCodecParameters{}, fmt.Errorf(
			"%w: dependency-descriptor extension was not negotiated", errFrameTrack,
		)
	}
	if context.WriteStream() == nil {
		track.mutex.Unlock()
		return webrtc.RTPCodecParameters{}, fmt.Errorf("%w: missing RTP writer", errFrameTrack)
	}
	seed := uint64(time.Now().UnixNano())
	track.referenceLedger.Reset("")
	track.bindings[context.ID()] = &frameTrackBinding{
		id: context.ID(), ssrc: context.SSRC(), payloadType: selected.PayloadType,
		profile:                         selectedProfile,
		metadataExtensionID:             uint8(metadataExtensionID),
		playoutDelayExtensionID:         uint8(playoutDelayExtensionID),
		dependencyDescriptorExtensionID: uint8(dependencyDescriptorExtensionID),
		sequence:                        uint16(seed), writer: context.WriteStream(),
	}
	onKeyframeRequest := track.onKeyframeRequest
	handlePLI := !track.pliHandledByInterceptor
	handleFIR := !track.firHandledByInterceptor
	if reader := context.RTCPReader(); reader != nil {
		go readFrameTrackRTCP(reader, onKeyframeRequest, handlePLI, handleFIR)
	}
	onBound := track.onBound
	track.mutex.Unlock()
	// WHAT THE FAR SIDE ACTUALLY AGREED TO, once per bind. rdev reports the codec it RESOLVED, which
	// answers "what are we sending" but never "why not the one I asked for" — and those are different
	// questions the moment a pin is a preference rather than a filter. A browser can advertise a codec
	// in getCapabilities and still omit it from the answer; from inside the host that is invisible,
	// and it presents as rdev ignoring the pin. Printed AFTER the unlock: this project keeps stdio out
	// of locked sections on principle.
	fmt.Printf("[bridge] bind %s: selected %s from the answer's %s\n",
		context.ID(), selectedProfile.statsName(), negotiatedCodecSummary(context.CodecParameters()))
	if onBound != nil {
		onBound()
	}
	return *selected, nil
}

// negotiatedCodecSummary names the video codecs an answer actually carried, for the bind log.
//
// RTX IS EXCLUDED: it doubles the list and says nothing about which picture codec was available,
// which is the only question this line exists to answer.
func negotiatedCodecSummary(codecs []webrtc.RTPCodecParameters) string {
	names := make([]string, 0, len(codecs))
	for _, candidate := range codecs {
		if strings.Contains(strings.ToLower(candidate.MimeType), "rtx") {
			continue
		}
		names = append(names, fmt.Sprintf("%s/%d", candidate.MimeType, candidate.PayloadType))
	}
	if len(names) == 0 {
		return "(none)"
	}
	return strings.Join(names, " ")
}

func (track *FrameTrack) SetOnBound(callback func()) {
	track.mutex.Lock()
	track.onBound = callback
	track.mutex.Unlock()
}

// SetOnFrameStart registers the frame clock. The callback takes the frame's STREAM id as well
// as its frame id: a session can carry several streams, each numbering its own frames from its own
// base, and a clock that saw only the frame id would read one stream's first frame as another's
// skipped one.
func (track *FrameTrack) SetOnFrameStart(callback func(streamID, frameID uint64) error) {
	track.mutex.Lock()
	track.onFrameStart = callback
	track.mutex.Unlock()
}

func (track *FrameTrack) SetOnKeyframeRequest(callback func()) {
	track.mutex.Lock()
	track.onKeyframeRequest = callback
	track.mutex.Unlock()
}

func (track *FrameTrack) SetPLIHandledByInterceptor(handled bool) {
	track.mutex.Lock()
	track.pliHandledByInterceptor = handled
	track.mutex.Unlock()
}

func (track *FrameTrack) SetOnKeyframeSent(callback func(uint32, uint16)) {
	track.mutex.Lock()
	track.onKeyframeSent = callback
	track.mutex.Unlock()
}

func (track *FrameTrack) IsBound() bool {
	track.mutex.Lock()
	defer track.mutex.Unlock()
	return len(track.bindings) != 0
}

func (track *FrameTrack) Unbind(context webrtc.TrackLocalContext) error {
	track.mutex.Lock()
	defer track.mutex.Unlock()
	if _, exists := track.bindings[context.ID()]; !exists {
		return webrtc.ErrUnbindFailed
	}
	delete(track.bindings, context.ID())
	track.referenceLedger.Reset("")
	return nil
}

// CarriesSSRC reports whether this track is currently bound to the given media SSRC.
//
// SSRC IS THE ONLY IDENTITY THE RTP LAYER HAS. A NACK or a PLI names a stream by SSRC and knows
// nothing about slots or source ids, so resolving one back to the track that owns it is what lets
// a keyframe request re-key the ONE window whose receiver asked, instead of every window on the
// session. It reads the bindings rather than caching an SSRC on the track because a track can be
// bound more than once and can unbind: a stale cached value would re-key the wrong slot, which is
// worse than the fan-out it replaces.
func (track *FrameTrack) CarriesSSRC(ssrc uint32) bool {
	track.mutex.Lock()
	defer track.mutex.Unlock()
	for _, binding := range track.bindings {
		if uint32(binding.ssrc) == ssrc {
			return true
		}
	}
	return false
}

// SetCodecPreference pins this track's preference order. Empty or nil means rdev's global order.
func (track *FrameTrack) SetCodecPreference(preference []codecID) {
	track.mutex.Lock()
	track.codecPreference = preference
	track.mutex.Unlock()
}

// NegotiatedCodec reports what the most recent Bind selected. False before any bind.
//
// The session reports this to rdev, which builds the source's ENCODER from it — so a wrong answer
// here silently encodes one codec onto a track that negotiated another: RTP flows, every state
// reads healthy, and nothing decodes.
func (track *FrameTrack) NegotiatedCodec() (codecID, bool) {
	track.mutex.Lock()
	defer track.mutex.Unlock()
	for _, binding := range track.bindings {
		return binding.profile.codec, true
	}
	return 0, false
}

// NegotiatedPayloadType is the payload type the answer settled on, or 0 before it binds.
//
// THE DataChannel PATH NEEDS IT AS MUCH AS RTP DOES. The client resolves its decoder codec from this
// value exactly as the encoded transform does from frame metadata; sending 0 leaves it unable to
// configure a decoder at all, so every symbol arrives, assembles, and is then refused for want of a
// codec — which reads as a transport failure and is not one.
func (track *FrameTrack) NegotiatedPayloadType() uint8 {
	track.mutex.Lock()
	defer track.mutex.Unlock()
	for _, binding := range track.bindings {
		return uint8(binding.payloadType)
	}
	return 0
}

func (track *FrameTrack) ID() string { return track.id }

func (track *FrameTrack) RID() string { return "" }

func (track *FrameTrack) StreamID() string { return track.streamID }

func (track *FrameTrack) Kind() webrtc.RTPCodecType { return webrtc.RTPCodecTypeVideo }

// captureGapNanos is the real time between the previous frame and this one, clamped.
//
// Called with track.mutex held.
func (track *FrameTrack) captureGapNanos(presentationNanos uint64) uint64 {
	if presentationNanos <= track.presentationNanos {
		// A TIMESTAMP MUST NEVER GO BACKWARDS — a receiver reads that as a stream reset and flushes.
		// rdev's source is DispatchTime uptime, which is monotonic, so this guards a future caller
		// rather than a case that fires today; equal instants are legal RTP and need no advance.
		return 0
	}
	gap := presentationNanos - track.presentationNanos
	if gap > maximumPresentationGapNanos {
		return maximumPresentationGapNanos
	}
	return gap
}

// elapsedTicks converts capture time to 90 kHz ticks, ROUNDED rather than truncated, and deliberately
// takes the total rather than one interval: the rounding then applies once to the whole span instead
// of once per frame, which is the difference between an error that is bounded and one that grows.
// The uint32 conversion is the RTP timestamp wrapping, which is normal and expected.
func elapsedTicks(elapsedNanos uint64) uint32 {
	return uint32((elapsedNanos*rtpClockRate + 500_000_000) / 1_000_000_000)
}

func (track *FrameTrack) WriteAccessUnit(frame OutboundFrame) error {
	if frame.ReferenceResult != nil {
		*frame.ReferenceResult = referenceSendResult{}
	}
	if frame.StreamID == 0 {
		return fmt.Errorf("%w: zero stream ID", errFrameTrack)
	}
	if len(frame.Data) == 0 || uint64(len(frame.Data)) > math.MaxUint32 {
		return fmt.Errorf("%w: invalid access-unit byte count %d", errFrameTrack, len(frame.Data))
	}
	if err := frame.Dependency.Validate(frame.Keyframe); err != nil {
		return err
	}

	track.mutex.Lock()
	defer track.mutex.Unlock()
	if len(track.bindings) == 0 {
		return fmt.Errorf("%w: no negotiated bindings", errFrameTrack)
	}
	// Validate dependency availability before consuming RTP counters or calling the
	// frame clock. No fabricated preceding-frame edge may repair a missing reference.
	var referenceID uint64
	var referenceDiffs []uint16
	var referenceChain uint8 = 1
	if m := frame.Reference; m != nil {
		if len(track.bindings) != 1 {
			return errReferenceRecovery
		}
		for _, b := range track.bindings {
			if b.profile.mimeType != webrtc.MimeTypeAV1 || b.dependencyDescriptorExtensionID == 0 {
				return errReferenceRecovery
			}
		}
		id, deps, err := m.validate(frame.Keyframe)
		if err != nil {
			return err
		}
		referenceID = id
		if frame.Keyframe {
			track.referenceLedger.Reset(m.Epoch)
		} else {
			referenceDiffs, err = track.referenceLedger.Dependencies(m.Epoch, deps, track.dependencyFrameNumber)
			if err != nil {
				return err
			}
			if m.RecoveryID != "" {
				if len(referenceDiffs) != 1 || referenceDiffs[0] > 255 {
					return errReferenceRecovery
				}
				referenceChain = uint8(referenceDiffs[0])
			} else {
				// The normal chain cannot cross a partially sent/missing preceding frame.
				found := track.referenceLedger.hasLast && track.referenceLedger.lastWire+1 == track.dependencyFrameNumber
				if !found {
					return errReferenceRecovery
				}
			}
		}
	} else {
		track.referenceLedger.Reset("")
	}
	descriptorFrameNumber := track.dependencyFrameNumber
	descriptor := func(first, last, attach bool) ([]byte, error) {
		if frame.Reference != nil && !frame.Keyframe {
			if referenceTestBadDescriptor && frame.Reference.RecoveryID != "" {
				return marshalReferenceDependencyDescriptor(descriptorFrameNumber, first, last, []uint16{1}, 1, true)
			}
			return marshalReferenceDependencyDescriptor(descriptorFrameNumber, first, last, referenceDiffs, referenceChain, frame.Reference.RecoveryID != "")
		}
		return marshalDependencyDescriptor(frame.Dependency, descriptorFrameNumber, first, last, attach)
	}
	if track.onFrameStart != nil {
		if err := track.onFrameStart(frame.StreamID, frame.FrameID); err != nil {
			return fmt.Errorf("%w: frame-start callback: %w", errFrameTrack, err)
		}
	}
	if frame.Started != nil {
		*frame.Started = true
	}
	// THE RTP TIMESTAMP IS THE RECEIVER'S PLAYOUT SCHEDULE, so it has to mean elapsed capture time.
	// The advance happens BEFORE the emit rather than after it, and that reordering is what makes a
	// real interval usable at all: the gap a frame needs is the one BEHIND it, which is knowable
	// only once its own presentation time is in hand. The first access unit still emits the seed
	// untouched, so the answering path's wire behaviour is unchanged.
	switch {
	case !track.wroteAccessUnit:
		// The first access unit emits the seed untouched and becomes the epoch every later
		// timestamp is measured from.
		track.baseTimestamp = track.timestamp
		track.elapsedNanos = 0
	case frame.PresentationNanos != 0 && track.hasPresentation:
		track.elapsedNanos += track.captureGapNanos(frame.PresentationNanos)
		track.timestamp = track.baseTimestamp + elapsedTicks(track.elapsedNanos)
	default:
		// NO PRESENTATION TIME: the fixed 60 fps step, byte for byte. This is LLV's answering path
		// (SendVideo), which is the certification's comparison arm and must not drift. Stepping the
		// accumulator alongside keeps it meaningful if timestamps ever resume mid-stream.
		track.timestamp += rtpClockStep
		track.elapsedNanos += fixedStepNanos
	}
	track.wroteAccessUnit = true
	if frame.PresentationNanos != 0 {
		track.presentationNanos = frame.PresentationNanos
		track.hasPresentation = true
	} else if track.hasPresentation {
		track.presentationNanos += fixedStepNanos
	}
	timestamp := track.timestamp
	dependencyFrameNumber := track.dependencyFrameNumber
	track.dependencyFrameNumber++

	var writeErrors []error
	for _, binding := range track.bindings {
		metadataTemplate := FrameMetadata{
			Version: frameMetadataVersion, Keyframe: frame.Keyframe,
			StreamID: frame.StreamID, FrameID: frame.FrameID,
			PacketCount: 1, OriginalAccessUnitBytes: uint32(len(frame.Data)),
			InputSequence:       frame.InputSequence,
			HostProcessingNanos: frame.HostProcessingNanos,
			EncodeNanos:         frame.EncodeNanos,
		}
		playoutDelayBytes, err := rtp.PlayoutDelayExtension{
			MinDelay: track.playoutDelayMinUnits, MaxDelay: track.playoutDelayMaxUnits,
		}.Marshal()
		if err != nil {
			return fmt.Errorf("%w: marshal playout delay: %v", errFrameTrack, err)
		}
		headerForSize := rtp.Header{Version: 2}
		if err := headerForSize.SetExtensionWithProfile(
			binding.playoutDelayExtensionID, playoutDelayBytes, rtp.ExtensionProfileTwoByte,
		); err != nil {
			return fmt.Errorf("%w: size playout-delay extension: %v", errFrameTrack, err)
		}
		if binding.metadataExtensionID != 0 {
			metadataBytes, err := metadataTemplate.MarshalBinary()
			if err != nil {
				return fmt.Errorf("%w: %v", errFrameTrack, err)
			}
			if err := headerForSize.SetExtensionWithProfile(
				binding.metadataExtensionID, metadataBytes, rtp.ExtensionProfileTwoByte,
			); err != nil {
				return fmt.Errorf("%w: size metadata extension: %v", errFrameTrack, err)
			}
		}
		// GUARDED LIKE THE PACKET SITE BELOW, and for a reason that is easy to miss: this reserves
		// header room for the descriptor. Leaving it unguarded on a codec that emits none would
		// shrink every payload by bytes the packets never carry — smaller pictures, no error.
		if binding.profile.emitsDependencyDescriptor {
			largestDescriptor, err := descriptor(
				true,
				false,
				frame.Keyframe,
			)
			if err != nil {
				return fmt.Errorf("%w: %v", errFrameTrack, err)
			}
			if err := headerForSize.SetExtensionWithProfile(
				binding.dependencyDescriptorExtensionID,
				largestDescriptor,
				rtp.ExtensionProfileTwoByte,
			); err != nil {
				return fmt.Errorf("%w: size dependency descriptor: %v", errFrameTrack, err)
			}
		}
		payloadBudget := maximumRTPBytes - headerForSize.MarshalSize()
		if payloadBudget <= 1 || payloadBudget > math.MaxUint16 {
			return fmt.Errorf("%w: invalid AV1 payload budget %d", errFrameTrack, payloadBudget)
		}
		payloads := newPayloaderFor(binding.profile).Payload(uint16(payloadBudget), frame.Data)
		if len(payloads) == 0 || len(payloads) > math.MaxUint16 {
			return fmt.Errorf("%w: %s payloader emitted %d packets",
				errFrameTrack, binding.profile.mimeType, len(payloads))
		}

		for index, payload := range payloads {
			metadata := metadataTemplate
			metadata.PacketIndex = uint16(index)
			metadata.PacketCount = uint16(len(payloads))
			encodedMetadata, err := metadata.MarshalBinary()
			if err != nil {
				return fmt.Errorf("%w: marshal packet metadata: %v", errFrameTrack, err)
			}
			packet := &rtp.Packet{
				Header: rtp.Header{
					Version: 2, Marker: index == len(payloads)-1,
					PayloadType:    uint8(binding.payloadType),
					SequenceNumber: binding.sequence,
					Timestamp:      timestamp, SSRC: uint32(binding.ssrc),
				},
				Payload: payload,
			}
			binding.sequence++
			if binding.metadataExtensionID != 0 {
				if err := packet.SetExtensionWithProfile(
					binding.metadataExtensionID, encodedMetadata, rtp.ExtensionProfileTwoByte,
				); err != nil {
					return fmt.Errorf("%w: set packet metadata: %v", errFrameTrack, err)
				}
			}
			// NOT WRITTEN when the header is disabled — the extension stays negotiated and the size
			// accounting above is unchanged, so packets are merely a few bytes under their estimate.
			// An absent playout-delay extension imposes no constraint, which is the point: the
			// receiver falls back to the jitter buffer it ships with.
			if index == 0 && !rdevPlayoutDelayHeaderOff {
				if err := packet.SetExtensionWithProfile(
					binding.playoutDelayExtensionID, playoutDelayBytes, rtp.ExtensionProfileTwoByte,
				); err != nil {
					return fmt.Errorf("%w: set playout-delay extension: %v", errFrameTrack, err)
				}
			}
			// AV1 ONLY. An H.264/H.265 receiver never negotiated this extension, and attaching it
			// anyway would put bytes on the wire the receiver has no id for.
			if binding.profile.emitsDependencyDescriptor {
				dependencyDescriptor, err := descriptor(
					index == 0,
					index == len(payloads)-1,
					frame.Keyframe && index == 0,
				)
				if err != nil {
					return fmt.Errorf("%w: %v", errFrameTrack, err)
				}
				if err := packet.SetExtensionWithProfile(
					binding.dependencyDescriptorExtensionID,
					dependencyDescriptor,
					rtp.ExtensionProfileTwoByte,
				); err != nil {
					return fmt.Errorf("%w: set dependency descriptor: %v", errFrameTrack, err)
				}
			}
			if packet.MarshalSize() > maximumRTPBytes {
				return fmt.Errorf("%w: RTP packet is %d bytes", errFrameTrack, packet.MarshalSize())
			}
			if frame.Keyframe && track.trace != nil {
				mediaSSRC := uint32(binding.ssrc)
				sequence := packet.SequenceNumber
				frameID := frame.FrameID
				payloadType := packet.PayloadType
				packetIndex := uint16(index)
				packetCount := uint16(len(payloads))
				marker := packet.Marker
				track.trace.Record(recoveryTraceEvent{
					Layer: traceLayerPionSender, Kind: traceKeyframePacketPacketized,
					MediaSSRC: &mediaSSRC, RTPSequence: &sequence,
					RTPTimestamp: &timestamp, FrameID: &frameID,
					PayloadType: &payloadType, PacketIndex: &packetIndex,
					PacketCount: &packetCount, Marker: &marker,
				})
			}
			if _, err := binding.writer.WriteRTP(&packet.Header, packet.Payload); err != nil {
				writeErrors = append(writeErrors, fmt.Errorf("binding %s: %w", binding.id, err))
				break
			}
			if frame.Keyframe && index == 0 {
				mediaSSRC := uint32(binding.ssrc)
				sequence := packet.SequenceNumber
				frameID := frame.FrameID
				track.trace.Record(recoveryTraceEvent{
					Layer: traceLayerPionSender, Kind: traceKeyframeFirstPacketEmitted,
					MediaSSRC: &mediaSSRC, RTPSequence: &sequence,
					RTPTimestamp: &timestamp, FrameID: &frameID,
				})
				if track.onKeyframeSent != nil {
					track.onKeyframeSent(uint32(binding.ssrc), packet.SequenceNumber)
				}
			}
		}
	}
	if len(writeErrors) != 0 {
		return fmt.Errorf("%w: %w", errFrameTrack, errors.Join(writeErrors...))
	}
	if frame.Reference != nil {
		result := referenceSendResult{RTPTimestamp: timestamp, WireFrameNumber: dependencyFrameNumber, Complete: true}
		track.referenceLedger.RecordSent(referenceID, result)
		track.referenceLedger.RecordToken(*frame.Reference, result)
		if frame.ReferenceResult != nil {
			*frame.ReferenceResult = result
		}
	}
	return nil
}

func readFrameTrackRTCP(
	reader interceptor.RTCPReader,
	requestKeyframe func(),
	handlePLI bool,
	handleFIR ...bool,
) {
	buffer := make([]byte, 1_500)
	for {
		read, _, err := reader.Read(buffer, nil)
		if err != nil {
			return
		}
		packets, err := rtcp.Unmarshal(buffer[:read])
		if err != nil {
			continue
		}
		requested := false
		for _, packet := range packets {
			switch packet.(type) {
			case *rtcp.PictureLossIndication:
				requested = requested || handlePLI
			case *rtcp.FullIntraRequest:
				requested = requested || len(handleFIR) == 0 || handleFIR[0]
			}
		}
		if requested && requestKeyframe != nil {
			requestKeyframe()
		}
	}
}

var _ webrtc.TrackLocal = (*FrameTrack)(nil)

func (track *FrameTrack) SetFIRHandledByInterceptor(handled bool) {
	track.mutex.Lock()
	track.firHandledByInterceptor = handled
	track.mutex.Unlock()
}
