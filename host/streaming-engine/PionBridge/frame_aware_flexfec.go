package main

import (
	"errors"
	"fmt"
	"strings"
	"sync"

	"github.com/pion/interceptor"
	"github.com/pion/interceptor/pkg/flexfec"
	"github.com/pion/rtp"
)

const maximumFlexFECMediaPackets = 109

var errFrameAwareFlexFEC = errors.New("frame-aware FlexFEC failed")

type FrameAwareFlexFECConfig struct {
	Tier           *FlexFECTierStore
	Override       *FlexFECOverrideStore
	Allocator      *TransportSequenceAllocator
	History        *TWCCPacketHistory
	Counters       *FlexFECCounters
	EgressBudget   *RecoveryFrameClockBudget
	EncoderFactory flexfec.EncoderFactory
	Disable        func(error)
}

type frameAwareFlexFECFactory struct {
	config  FrameAwareFlexFECConfig
	disable frameAwareFlexFECDisable
}

type frameAwareFlexFECDisable struct {
	once sync.Once
}

func NewFrameAwareFlexFEC(config FrameAwareFlexFECConfig) (interceptor.Factory, error) {
	if config.Tier == nil || config.Override == nil || config.Allocator == nil ||
		config.History == nil || config.Counters == nil {
		return nil, fmt.Errorf("%w: incomplete configuration", errFrameAwareFlexFEC)
	}
	if config.EncoderFactory == nil {
		config.EncoderFactory = flexfec.FlexEncoder03Factory{}
	}
	if config.Disable == nil {
		config.Disable = func(error) {}
	}
	return &frameAwareFlexFECFactory{config: config}, nil
}

func (factory *frameAwareFlexFECFactory) NewInterceptor(_ string) (interceptor.Interceptor, error) {
	return &frameAwareFlexFEC{
		config: factory.config, disable: &factory.disable,
		streams: make(map[uint32]*frameAwareFlexFECStream),
	}, nil
}

type frameAwareFlexFEC struct {
	interceptor.NoOp
	config  FrameAwareFlexFECConfig
	disable *frameAwareFlexFECDisable
	mutex   sync.Mutex
	streams map[uint32]*frameAwareFlexFECStream
}

type frameAwareFlexFECStream struct {
	mutex sync.Mutex

	mediaSSRC             uint32
	fecSSRC               uint32
	metadataExtensionID   uint8
	dependencyExtensionID uint8
	twccExtensionID       uint8
	// The codec this stream negotiated, used only when no dependency descriptor was negotiated —
	// it selects the NAL keyframe parser.
	profile videoCodecProfile
	encoder flexfec.FlexEncoder
	frame   *frameAwareFlexFECFrame
}

type frameAwareFlexFECFrame struct {
	metadata  *FrameMetadata
	boundary  frameBoundary
	timestamp uint32
	keyframe  bool
	shape     flexFECShape
	packets   []rtp.Packet
}

func (fec *frameAwareFlexFEC) BindLocalStream(
	info *interceptor.StreamInfo,
	writer interceptor.RTPWriter,
) interceptor.RTPWriter {
	// AN AUDIO STREAM IS NOT A FAILURE, IT IS NOT OURS. Every local stream binds through here, and
	// rdev registers FlexFEC for VIDEO ONLY — so an Opus track has no FEC association by design and
	// tripped the check below, disabling FlexFEC for the whole session through a one-shot
	// sync.Once. Observed on a running host as `[bridge] fec: DEGRADED to nack-rtx` every five
	// seconds while the picture streamed perfectly: the recovery stack the video depends on, turned
	// off by the arrival of a track that never wanted it.
	//
	// TESTED BY MIME TYPE, AND ONLY FOR *EXPLICIT* AUDIO — never as "anything that is not video".
	// An empty or unfamiliar MimeType still falls through to the checks below and still fails
	// loudly, because a video stream that arrives without its FEC association IS the misconfiguration
	// this guard exists to catch, and inverting the test would silence exactly that case.
	if info != nil && strings.HasPrefix(strings.ToLower(info.MimeType), "audio/") {
		return writer
	}
	if info == nil || writer == nil || info.SSRC == 0 || info.SSRCForwardErrorCorrection == 0 ||
		info.PayloadTypeForwardErrorCorrection == 0 {
		fec.fail(fmt.Errorf("%w: missing negotiated media or repair stream", errFrameAwareFlexFEC))
		return writer
	}
	metadataID := extensionID(info, frameMetadataURI)
	dependencyID := extensionID(info, dependencyDescriptorURI)
	twccID := extensionID(info, twccURI)
	if dependencyID == 0 || twccID == 0 {
		fec.fail(fmt.Errorf(
			"%w: missing required standards RTP header extension dependency=%d twcc=%d available=%v",
			errFrameAwareFlexFEC, dependencyID, twccID, info.RTPHeaderExtensions,
		))
		return writer
	}
	// AN UNREGISTERED PAYLOAD TYPE CANNOT BE CLASSIFIED, and guessing would put the WRONG ratio on
	// keyframes. The fallback is the AV1 profile deliberately: keyframeFromPayload returns false
	// there, so an unknown codec LOSES the keyframe boost rather than misapplying it.
	profile, ok := profileForPayloadType(uint8(info.PayloadType))
	if !ok {
		profile = videoCodecProfiles()[0]
	}
	stream := &frameAwareFlexFECStream{
		mediaSSRC: info.SSRC, fecSSRC: info.SSRCForwardErrorCorrection,
		metadataExtensionID: metadataID, dependencyExtensionID: dependencyID,
		twccExtensionID: twccID, profile: profile,
		encoder: fec.config.EncoderFactory.NewEncoder(
			info.PayloadTypeForwardErrorCorrection, info.SSRCForwardErrorCorrection,
		),
	}
	if stream.encoder == nil {
		fec.fail(fmt.Errorf("%w: encoder factory returned nil", errFrameAwareFlexFEC))
		return writer
	}
	fec.mutex.Lock()
	fec.streams[info.SSRC] = stream
	fec.mutex.Unlock()
	return interceptor.RTPWriterFunc(func(
		header *rtp.Header,
		payload []byte,
		attributes interceptor.Attributes,
	) (int, error) {
		shape := currentFlexFECShape(fec.config.Tier, fec.config.Override)
		if header == nil || header.SSRC != stream.mediaSSRC || shape.silent() && stream.frame == nil {
			return writer.Write(header, payload, attributes)
		}
		stream.mutex.Lock()
		complete, validationErr := stream.accept(header, payload, shape)
		stream.mutex.Unlock()
		result, mediaErr := writer.Write(header, payload, attributes)
		if validationErr != nil {
			fec.fail(validationErr)
			return result, mediaErr
		}
		if complete == nil || complete.shape.silent() ||
			!selectFlexFECFrame(complete.shape, complete.keyframe, complete.boundary.temporalID) {
			return result, mediaErr
		}
		repairErr := fec.emitFrameRepairs(stream, complete, writer, attributes)
		return result, errors.Join(mediaErr, repairErr)
	})
}

func extensionID(info *interceptor.StreamInfo, uri string) uint8 {
	for _, extension := range info.RTPHeaderExtensions {
		if extension.URI == uri && extension.ID > 0 && extension.ID <= 255 {
			return uint8(extension.ID)
		}
	}
	return 0
}

func (stream *frameAwareFlexFECStream) accept(
	header *rtp.Header,
	payload []byte,
	shape flexFECShape,
) (*frameAwareFlexFECFrame, error) {
	// THIS BRANCH DOES NOT RUN AGAINST A BROWSER, AND THE CROSS-CHECK BELOW IS THEREFORE INERT IN
	// PRODUCTION. Measured 2026-08-19: rdev offers four video header extensions and Chrome's answer
	// keeps playout-delay, the AV1 dependency descriptor and TWCC — and DROPS
	// `urn:llv:rtp-frame-metadata:1`. So metadataExtensionID is 0 on every browser session,
	// `FrameTrack` never attaches frame metadata to a browser-bound packet, and the
	// "metadata and dependency descriptor disagree" refusal can only fire against a receiver that
	// negotiates the extension — RdevViewer and `llv capture-view`, i.e. rdev's own instruments.
	//
	// It is kept because guarding the instrument path is worth something and costs nothing. What it
	// must NOT be read as is protection for the path that carries users; a reader reaching for it as
	// the reason some browser-side corruption is impossible would be wrong.
	var metadata *FrameMetadata
	if stream.metadataExtensionID != 0 {
		parsed, err := ParseFrameMetadata(header.GetExtension(stream.metadataExtensionID))
		if err != nil {
			stream.frame = nil
			return nil, fmt.Errorf("%w: metadata: %v", errFrameAwareFlexFEC, err)
		}
		metadata = &parsed
	}
	// WHICH SOURCE RUNS IS DECIDED BY WHAT WAS NEGOTIATED, not by the codec directly. A receiver that
	// negotiates the dependency descriptor takes the descriptor path whatever it is decoding —
	// RdevViewer and `llv capture-view` do — so this cannot regress them by construction.
	var boundary frameBoundary
	if stream.dependencyExtensionID != 0 && len(header.GetExtension(stream.dependencyExtensionID)) > 0 {
		parsed, err := boundaryFromDescriptor(header.GetExtension(stream.dependencyExtensionID))
		if err != nil {
			stream.frame = nil
			return nil, fmt.Errorf("%w: dependency descriptor: %v", errFrameAwareFlexFEC, err)
		}
		boundary = parsed
	} else {
		boundary = boundaryFromRTP(header, payload, stream.profile, stream.frame != nil)
	}
	first := boundary.first
	last := boundary.last
	keyframe := boundary.keyframe
	if metadata != nil {
		metadataFirst := metadata.PacketIndex == 0
		metadataLast := metadata.PacketIndex+1 == metadata.PacketCount
		if first != metadataFirst || last != metadataLast || metadata.Keyframe != keyframe {
			stream.frame = nil
			return nil, fmt.Errorf("%w: metadata and dependency descriptor disagree", errFrameAwareFlexFEC)
		}
	}
	if header.Marker != last {
		stream.frame = nil
		return nil, fmt.Errorf("%w: frame boundary or keyframe disagreement", errFrameAwareFlexFEC)
	}
	if stream.frame == nil {
		if !first {
			// RESYNC, NOT AN ERROR — and treating it as one disabled FlexFEC the instant it became
			// useful. While the controller sits at tier 0 the interceptor short-circuits above
			// (`shape.silent() && stream.frame == nil`) and NO packet reaches this function, so
			// `stream.frame` is nil by construction. The moment the controller decides to protect
			// something, the next packet arrives here mid-frame — which this guard read as
			// corruption and answered by failing FlexFEC for the whole session.
			//
			// MEASURED: `recovery policy seq=2 tier=1` followed immediately by `FlexFEC disabled —
			// frame begins after packet zero`. At two or three packets per frame the transition
			// lands mid-frame about half the time, so adaptive FlexFEC was close to a coin flip.
			//
			// THE PREMISE WAS WRONG, NOT THE LOGIC: the guard assumed `accept` sees every packet,
			// which the tier-0 bypass violates by design. Skipping to the next frame start is the
			// correct response and is bounded at one partial frame per activation.
			return nil, nil
		}
		capacity := 1
		if metadata != nil {
			capacity = int(metadata.PacketCount)
		}
		stream.frame = &frameAwareFlexFECFrame{
			metadata: metadata, boundary: boundary, timestamp: header.Timestamp,
			keyframe: keyframe, shape: shape,
			packets: make([]rtp.Packet, 0, capacity),
		}
	} else {
		frame := stream.frame
		if first {
			stream.frame = nil
			return nil, fmt.Errorf("%w: new frame arrived before prior frame completed", errFrameAwareFlexFEC)
		}
		// COMPARED ONLY WHEN BOTH PACKETS CARRIED A DESCRIPTOR, which keeps AV1 byte-for-byte what it
		// was. The NAL source has no TemplateID and cannot re-derive `keyframe` from a continuation
		// packet at all (an FU-A continuation carries no NAL type), so comparing either against the
		// frame in progress would reject every fragmented keyframe. Timestamp and sequence
		// consecutiveness are what BOTH sources can assert, and they are asserted for both.
		if boundary.descriptor != nil && frame.boundary.descriptor != nil {
			if boundary.descriptor.TemplateID != frame.boundary.descriptor.TemplateID ||
				boundary.descriptor.TemporalID != frame.boundary.descriptor.TemporalID {
				stream.frame = nil
				return nil, fmt.Errorf("%w: inconsistent or non-consecutive frame packet", errFrameAwareFlexFEC)
			}
		}
		if header.Timestamp != frame.timestamp ||
			header.SequenceNumber != frame.packets[len(frame.packets)-1].SequenceNumber+1 {
			stream.frame = nil
			return nil, fmt.Errorf("%w: inconsistent or non-consecutive frame packet", errFrameAwareFlexFEC)
		}
		if metadata != nil {
			if frame.metadata == nil || metadata.FrameID != frame.metadata.FrameID ||
				metadata.StreamID != frame.metadata.StreamID ||
				!metadata.sameFrame(*frame.metadata) ||
				metadata.PacketIndex != uint16(len(frame.packets)) {
				stream.frame = nil
				return nil, fmt.Errorf("%w: inconsistent frame metadata", errFrameAwareFlexFEC)
			}
		}
	}
	clonedHeader := header.Clone()
	stream.frame.packets = append(stream.frame.packets, rtp.Packet{
		Header: clonedHeader, Payload: append([]byte(nil), payload...),
	})
	if !last {
		return nil, nil
	}
	complete := stream.frame
	stream.frame = nil
	if complete.metadata != nil && len(complete.packets) != int(complete.metadata.PacketCount) {
		return nil, fmt.Errorf("%w: incomplete declared frame", errFrameAwareFlexFEC)
	}
	return complete, nil
}

// selectFlexFECFrame decides whether a frame is protected at all.
//
// A FORCED RATIO IGNORES THE TEMPORAL-LAYER TEST BELOW, and deliberately. That test is what makes
// Low/Medium/High differ at L1T2 and L1T3; at rdev's L1T1 there is only layer 0, so it is inert
// there and every tier protects every frame. An override must not inherit a distinction that
// depends on a scalability mode the operator did not choose.
func selectFlexFECFrame(shape flexFECShape, keyframe bool, temporalID uint8) bool {
	if shape.overridden {
		return shape.overrideBp > 0
	}
	if shape.tier == FlexFECTierOff {
		return false
	}
	if keyframe {
		return true
	}
	switch shape.tier {
	case FlexFECTierLow:
		return temporalID == 0
	case FlexFECTierMedium:
		return temporalID <= 1
	case FlexFECTierHigh:
		return temporalID <= 2
	default:
		return false
	}
}

// flexFECRepairCount is how many repair packets a frame's media packets earn.
//
// THE KEYFRAME CASE IS THE ONE PLACE AN OVERRIDE DIVERGES FROM THE IMPORTED ENGINE. Under Auto,
// keyframes are pinned at 2/5 whatever the tier — so a forced 10% would carry more overhead than
// it claims, and a forced 0% would still put FEC on the wire. Both would make the number in the
// titlebar a lie, which is the whole reason this knob is one number rather than two. The
// divergence applies ONLY while an override is set; Auto below is byte-for-byte the imported rule,
// which is what keeps the answering path — the certification's comparison arm — unchanged.
func flexFECRepairCount(shape flexFECShape, keyframe bool, mediaPackets int) uint32 {
	if mediaPackets <= 0 {
		return 0
	}
	if shape.overridden {
		if shape.overrideBp == 0 {
			return 0
		}
		// Rounds UP, so a short frame at a small ratio still earns one repair packet rather than
		// silently none — a frame protected by zero packets is an unprotected frame.
		return uint32((uint64(mediaPackets)*uint64(shape.overrideBp) + 9_999) / 10_000)
	}
	numerator, denominator := 0, 1
	if keyframe {
		numerator, denominator = 2, 5
	} else {
		switch shape.tier {
		case FlexFECTierLow:
			numerator, denominator = 1, 10
		case FlexFECTierMedium:
			numerator, denominator = 1, 5
		case FlexFECTierHigh:
			numerator, denominator = 2, 5
		}
	}
	if numerator == 0 {
		return 0
	}
	return uint32((mediaPackets*numerator + denominator - 1) / denominator) //nolint:gosec
}

type generatedFlexFECGroup struct {
	mediaCount int
	packets    []rtp.Packet
}

func (fec *frameAwareFlexFEC) emitFrameRepairs(
	stream *frameAwareFlexFECStream,
	frame *frameAwareFlexFECFrame,
	writer interceptor.RTPWriter,
	attributes interceptor.Attributes,
) error {
	stream.mutex.Lock()
	groups := make([]generatedFlexFECGroup, 0, (len(frame.packets)+maximumFlexFECMediaPackets-1)/maximumFlexFECMediaPackets)
	var generationErr error
	for start := 0; start < len(frame.packets); start += maximumFlexFECMediaPackets {
		end := min(start+maximumFlexFECMediaPackets, len(frame.packets))
		media := frame.packets[start:end]
		for index := range media {
			if err := zeroFlexFECMutableExtensions(&media[index], stream.twccExtensionID); err != nil {
				generationErr = err
				break
			}
		}
		if generationErr != nil {
			break
		}
		requested := flexFECRepairCount(frame.shape, frame.keyframe, len(media))
		packets := stream.encoder.EncodeFec(media, requested)
		if requested == 0 || len(packets) != int(requested) {
			generationErr = fmt.Errorf(
				"%w: encoder returned %d repairs, requested %d", errFrameAwareFlexFEC, len(packets), requested,
			)
			break
		}
		groups = append(groups, generatedFlexFECGroup{mediaCount: len(media), packets: packets})
	}
	stream.mutex.Unlock()
	if generationErr != nil {
		fec.fail(generationErr)
		return nil
	}
	fec.config.Counters.recordSelectedFrame(frame.boundary.temporalID)
	var writeErrors []error
	for _, group := range groups {
		fecBytes := 0
		emittedPackets := 0
		for index := range group.packets {
			packet := &group.packets[index]
			packet.Timestamp = frame.timestamp
			if err := packet.SetExtension(stream.twccExtensionID, []byte{0, 0}); err != nil {
				writeErrors = append(writeErrors, err)
				continue
			}
			packetBytes := packet.MarshalSize()
			if fec.config.EgressBudget != nil {
				admitted, err := fec.config.EgressBudget.TryAdmitRecovery(
					TWCCFEC, packetBytes,
				)
				if err != nil {
					writeErrors = append(writeErrors, err)
					continue
				}
				if !admitted {
					continue
				}
			}
			sequence := fec.config.Allocator.Next()
			extension, err := (&rtp.TransportCCExtension{TransportSequence: sequence}).Marshal()
			if err != nil {
				writeErrors = append(writeErrors, err)
				continue
			}
			if err := packet.SetExtension(stream.twccExtensionID, extension); err != nil {
				writeErrors = append(writeErrors, err)
				continue
			}
			fec.config.History.RecordSent(TWCCSentPacket{
				SSRC: packet.SSRC, RTPSequence: packet.SequenceNumber,
				TransportSequence: sequence, Class: TWCCFEC,
				Bytes: packetBytes, Departure: fec.config.History.now(),
			})
			if _, err := writer.Write(&packet.Header, packet.Payload, attributes); err != nil {
				writeErrors = append(writeErrors, err)
			}
			fecBytes += packetBytes
			emittedPackets++
		}
		if emittedPackets > 0 {
			fec.config.Counters.recordGroup(group.mediaCount, emittedPackets, fecBytes)
		}
	}
	return errors.Join(writeErrors...)
}

func zeroFlexFECMutableExtensions(packet *rtp.Packet, twccExtensionID uint8) error {
	if packet == nil || twccExtensionID == 0 {
		return fmt.Errorf("%w: missing mutable TWCC extension", errFrameAwareFlexFEC)
	}
	value := packet.GetExtension(twccExtensionID)
	if len(value) == 0 {
		return nil
	}
	if len(value) != 2 {
		return fmt.Errorf(
			"%w: mutable TWCC extension length %d", errFrameAwareFlexFEC, len(value),
		)
	}
	if err := packet.SetExtension(twccExtensionID, []byte{0, 0}); err != nil {
		return fmt.Errorf("%w: zero mutable TWCC extension: %v", errFrameAwareFlexFEC, err)
	}
	return nil
}

func (fec *frameAwareFlexFEC) fail(err error) {
	if err == nil {
		return
	}
	fec.disable.once.Do(func() {
		fec.config.Tier.Set(FlexFECTierOff)
		// AND THE OVERRIDE, or a forced ratio would keep selecting frames for an encoder that has
		// already failed — the tier being set to Off would protect nothing, because an override
		// outranks it by design. A session whose FEC has failed returns to Auto, where the tier is
		// Off and stays Off.
		fec.config.Override.Clear()
		fec.config.Counters.recordFailure(err)
		fec.config.Disable(err)
	})
}

func (fec *frameAwareFlexFEC) UnbindLocalStream(info *interceptor.StreamInfo) {
	if info == nil {
		return
	}
	fec.mutex.Lock()
	stream := fec.streams[info.SSRC]
	delete(fec.streams, info.SSRC)
	fec.mutex.Unlock()
	if stream != nil {
		stream.mutex.Lock()
		incomplete := stream.frame != nil
		stream.frame = nil
		stream.mutex.Unlock()
		if incomplete {
			fec.fail(fmt.Errorf("%w: stream unbound with incomplete frame", errFrameAwareFlexFEC))
		}
	}
}

func (fec *frameAwareFlexFEC) Close() error {
	fec.mutex.Lock()
	streams := make([]*frameAwareFlexFECStream, 0, len(fec.streams))
	for _, stream := range fec.streams {
		streams = append(streams, stream)
	}
	fec.streams = make(map[uint32]*frameAwareFlexFECStream)
	fec.mutex.Unlock()
	for _, stream := range streams {
		stream.mutex.Lock()
		incomplete := stream.frame != nil
		stream.frame = nil
		stream.mutex.Unlock()
		if incomplete {
			fec.fail(fmt.Errorf("%w: interceptor closed with incomplete frame", errFrameAwareFlexFEC))
		}
	}
	return nil
}
