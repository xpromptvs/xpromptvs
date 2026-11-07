package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/pion/rtp"
	"github.com/pion/rtp/codecs"
	"github.com/pion/webrtc/v4"
)

const (
	defaultRecoveryByteLimit = 32 << 20
)

var errFrameAssembly = errors.New("frame assembly failed")

type AssembledFrame struct {
	Metadata              FrameMetadata
	Data                  []byte
	FirstPacketNanos      uint64
	AssemblyDurationNanos uint64
}

type AssemblyDisposition uint8

const (
	AssemblyPending AssemblyDisposition = iota
	AssemblyComplete
	AssemblyDuplicate
	AssemblyStale
	AssemblySuperseded
)

type FrameAssemblerConfig struct {
	ExtensionID       uint8
	RecoveryWindow    time.Duration
	MaxRetainedFrames int
	MaxRetainedBytes  int
	Counters          *RecoveryCounters
}

type AssemblyResult struct {
	Disposition      AssemblyDisposition
	Frames           []AssembledFrame
	KeyframeRequired bool
	KeyframeStreamID uint64
}

type FrameAssemblerStats struct {
	PendingFrames  int
	RetainedFrames int
	Completed      uint64
	Duplicates     uint64
	Stale          uint64
	Superseded     uint64
	Malformed      uint64
	StreamChanges  uint64
}

type pendingFrame struct {
	metadata         FrameMetadata
	payloads         [][]byte
	received         int
	firstPacketNanos uint64
	timestamp        uint32
	ssrc             uint32
	byteCharge       int
	complete         *AssembledFrame
}

type FrameAssembler struct {
	mutex  sync.Mutex
	config FrameAssemblerConfig

	streamID        uint64
	hasStream       bool
	nextDeliverable uint64
	hasNext         bool
	pending         map[uint64]*pendingFrame
	retainedBytes   int
	lossActive      bool
	lossStartNanos  uint64
	waitingKeyframe bool
	stats           FrameAssemblerStats
}

func NewFrameAssembler(config FrameAssemblerConfig) (*FrameAssembler, error) {
	if config.ExtensionID == 0 || config.RecoveryWindow < 0 ||
		config.MaxRetainedFrames < 0 || config.MaxRetainedBytes < 0 {
		return nil, fmt.Errorf("%w: invalid configuration", errFrameAssembly)
	}
	if config.RecoveryWindow == 0 {
		config.MaxRetainedFrames = 1
	} else if config.MaxRetainedFrames == 0 {
		config.MaxRetainedFrames = defaultRecoveryFrameLimit
	}
	if config.MaxRetainedBytes == 0 {
		config.MaxRetainedBytes = defaultRecoveryByteLimit
	}
	if config.Counters == nil {
		config.Counters = &RecoveryCounters{}
	}
	return &FrameAssembler{config: config, pending: make(map[uint64]*pendingFrame)}, nil
}

func (assembler *FrameAssembler) Push(
	packet *rtp.Packet,
	receiveNanos uint64,
) (AssemblyResult, error) {
	assembler.mutex.Lock()
	defer assembler.mutex.Unlock()

	if packet == nil {
		return assembler.malformed("nil RTP packet")
	}
	metadataBytes := packet.GetExtension(assembler.config.ExtensionID)
	if len(metadataBytes) == 0 {
		return assembler.malformed("missing frame metadata extension")
	}
	metadata, err := ParseFrameMetadata(metadataBytes)
	if err != nil {
		return assembler.malformed(err.Error())
	}
	if packet.Marker != (metadata.PacketIndex == metadata.PacketCount-1) {
		return assembler.malformed("RTP marker does not match packet index")
	}

	if assembler.hasStream && assembler.lossExpired(receiveNanos) {
		result := assembler.requireKeyframe()
		if !metadata.Keyframe {
			return result, nil
		}
		if assembler.streamID != metadata.StreamID {
			assembler.stats.StreamChanges++
			assembler.streamID = metadata.StreamID
		}
		assembler.startFromKeyframe(metadata.FrameID)
		return assembler.pushValidated(packet, metadata, receiveNanos, result)
	}

	if !assembler.hasStream || assembler.streamID != metadata.StreamID {
		if assembler.hasStream && !metadata.Keyframe {
			return assembler.malformed("stream changed without a keyframe")
		}
		if assembler.hasStream {
			assembler.stats.StreamChanges++
		}
		assembler.clearPending()
		assembler.streamID = metadata.StreamID
		assembler.hasStream = true
		assembler.nextDeliverable = metadata.FrameID
		assembler.hasNext = true
		assembler.waitingKeyframe = false
		assembler.lossActive = false
		assembler.lossStartNanos = 0
	}

	if assembler.waitingKeyframe {
		if !metadata.Keyframe {
			assembler.stats.Stale++
			return AssemblyResult{Disposition: AssemblyStale}, nil
		}
		assembler.startFromKeyframe(metadata.FrameID)
	}

	if assembler.hasNext && metadata.FrameID < assembler.nextDeliverable {
		assembler.stats.Stale++
		return AssemblyResult{Disposition: AssemblyStale}, nil
	}
	base := AssemblyResult{}
	if assembler.hasNext && metadata.FrameID > assembler.nextDeliverable {
		if metadata.Keyframe {
			assembler.abandonForKeyframe(metadata.FrameID)
			base.Disposition = AssemblySuperseded
		} else if assembler.config.RecoveryWindow == 0 {
			assembler.supersedeWithoutRecovery(metadata.FrameID)
			base.Disposition = AssemblySuperseded
		} else {
			assembler.activateLoss(receiveNanos)
		}
	}

	return assembler.pushValidated(packet, metadata, receiveNanos, base)
}

func (assembler *FrameAssembler) Inspect(receiveNanos uint64) AssemblyResult {
	assembler.mutex.Lock()
	defer assembler.mutex.Unlock()
	if assembler.hasStream && assembler.lossExpired(receiveNanos) {
		return assembler.requireKeyframe()
	}
	return AssemblyResult{Disposition: AssemblyPending}
}

func (assembler *FrameAssembler) pushValidated(
	packet *rtp.Packet,
	metadata FrameMetadata,
	receiveNanos uint64,
	base AssemblyResult,
) (AssemblyResult, error) {
	disposition := AssemblyPending
	frame := assembler.pending[metadata.FrameID]
	if frame == nil {
		frame = &pendingFrame{
			metadata:         metadata,
			payloads:         make([][]byte, int(metadata.PacketCount)),
			firstPacketNanos: receiveNanos,
			timestamp:        packet.Timestamp,
			ssrc:             packet.SSRC,
		}
		assembler.pending[metadata.FrameID] = frame
		assembler.updateRetainedCounter()
	} else {
		if !frame.metadata.sameFrame(metadata) {
			return assembler.malformed("conflicting repeated frame metadata")
		}
		if frame.timestamp != packet.Timestamp || frame.ssrc != packet.SSRC {
			return assembler.malformed("conflicting RTP frame identity")
		}
		if frame.complete != nil {
			assembler.stats.Duplicates++
			return AssemblyResult{Disposition: AssemblyDuplicate}, nil
		}
	}

	index := int(metadata.PacketIndex)
	if existing := frame.payloads[index]; existing != nil {
		if !bytes.Equal(existing, packet.Payload) {
			return assembler.malformed("conflicting duplicate RTP payload")
		}
		assembler.stats.Duplicates++
		return AssemblyResult{Disposition: AssemblyDuplicate}, nil
	}
	frame.payloads[index] = append([]byte(nil), packet.Payload...)
	frame.received++
	frame.byteCharge += len(packet.Payload)
	assembler.retainedBytes += len(packet.Payload)

	if frame.received == len(frame.payloads) {
		completed, err := assemblePendingFrame(frame, receiveNanos)
		if err != nil {
			return assembler.malformed(err.Error())
		}
		assembler.retainedBytes -= frame.byteCharge
		frame.payloads = nil
		frame.byteCharge = len(completed.Data)
		assembler.retainedBytes += frame.byteCharge
		frame.complete = &completed
	}

	frames := assembler.drainComplete()
	if len(frames) != 0 {
		disposition = AssemblyComplete
		assembler.stats.Completed += uint64(len(frames))
	}
	if assembler.lossActive && (len(assembler.pending) > assembler.config.MaxRetainedFrames ||
		assembler.retainedBytes > assembler.config.MaxRetainedBytes) {
		return assembler.requireKeyframe(), nil
	}
	assembler.updateRetainedCounter()
	if disposition != AssemblyPending {
		base.Disposition = disposition
	}
	base.Frames = frames
	return base, nil
}

func assemblePendingFrame(frame *pendingFrame, receiveNanos uint64) (AssembledFrame, error) {
	depacketizer := &codecs.AV1Depacketizer{}
	normalized := make([]byte, 0, int(frame.metadata.OriginalAccessUnitBytes))
	for _, payload := range frame.payloads {
		chunk, err := depacketizer.Unmarshal(payload)
		if err != nil {
			return AssembledFrame{}, err
		}
		normalized = append(normalized, chunk...)
	}
	if len(normalized) == 0 {
		return AssembledFrame{}, errors.New("depacketizer emitted an empty access unit")
	}
	metadata := frame.metadata
	metadata.PacketIndex = 0
	duration := uint64(0)
	if receiveNanos >= frame.firstPacketNanos {
		duration = receiveNanos - frame.firstPacketNanos
	}
	return AssembledFrame{
		Metadata: metadata, Data: normalized,
		FirstPacketNanos:      frame.firstPacketNanos,
		AssemblyDurationNanos: duration,
	}, nil
}

func (assembler *FrameAssembler) drainComplete() []AssembledFrame {
	var frames []AssembledFrame
	for assembler.hasNext {
		frame := assembler.pending[assembler.nextDeliverable]
		if frame == nil || frame.complete == nil {
			break
		}
		frames = append(frames, *frame.complete)
		assembler.retainedBytes -= frame.byteCharge
		delete(assembler.pending, assembler.nextDeliverable)
		assembler.nextDeliverable++
	}
	if len(assembler.pending) == 0 {
		assembler.lossActive = false
		assembler.lossStartNanos = 0
	}
	return frames
}

func (assembler *FrameAssembler) activateLoss(provenNanos uint64) {
	if assembler.lossActive {
		return
	}
	assembler.lossActive = true
	assembler.lossStartNanos = provenNanos
	if missing := assembler.pending[assembler.nextDeliverable]; missing != nil {
		assembler.lossStartNanos = missing.firstPacketNanos
	}
	assembler.updateRetainedCounter()
}

func (assembler *FrameAssembler) lossExpired(receiveNanos uint64) bool {
	if !assembler.lossActive || assembler.config.RecoveryWindow == 0 {
		return false
	}
	window := uint64(assembler.config.RecoveryWindow)
	return receiveNanos > assembler.lossStartNanos &&
		receiveNanos-assembler.lossStartNanos > window
}

func (assembler *FrameAssembler) requireKeyframe() AssemblyResult {
	incomplete := uint64(0)
	dependent := uint64(0)
	if frame := assembler.pending[assembler.nextDeliverable]; frame == nil || frame.complete == nil {
		incomplete = 1
	}
	for frameID, frame := range assembler.pending {
		if frameID > assembler.nextDeliverable && frame.complete != nil {
			dependent++
		}
	}
	assembler.config.Counters.addIncompleteFramesExpired(incomplete)
	assembler.config.Counters.addDependentFramesAbandoned(dependent)
	streamID := assembler.streamID
	assembler.clearPending()
	assembler.waitingKeyframe = true
	assembler.lossActive = false
	assembler.lossStartNanos = 0
	assembler.stats.Superseded++
	return AssemblyResult{
		Disposition:      AssemblySuperseded,
		KeyframeRequired: true,
		KeyframeStreamID: streamID,
	}
}

func (assembler *FrameAssembler) startFromKeyframe(frameID uint64) {
	assembler.clearPending()
	assembler.nextDeliverable = frameID
	assembler.hasNext = true
	assembler.waitingKeyframe = false
	assembler.lossActive = false
	assembler.lossStartNanos = 0
}

func (assembler *FrameAssembler) abandonForKeyframe(frameID uint64) {
	for _, frame := range assembler.pending {
		if frame.complete != nil {
			assembler.config.Counters.addDependentFramesAbandoned(1)
		}
	}
	assembler.stats.Superseded++
	assembler.startFromKeyframe(frameID)
}

func (assembler *FrameAssembler) supersedeWithoutRecovery(frameID uint64) {
	assembler.stats.Superseded++
	assembler.clearPending()
	assembler.nextDeliverable = frameID
	assembler.hasNext = true
}

func (assembler *FrameAssembler) clearPending() {
	for _, frame := range assembler.pending {
		for index := range frame.payloads {
			frame.payloads[index] = nil
		}
		if frame.complete != nil {
			frame.complete.Data = nil
		}
	}
	assembler.pending = make(map[uint64]*pendingFrame)
	assembler.retainedBytes = 0
	assembler.updateRetainedCounter()
}

func (assembler *FrameAssembler) updateRetainedCounter() {
	retained := uint64(0)
	if assembler.lossActive {
		retained = uint64(len(assembler.pending))
	}
	assembler.config.Counters.setRetainedFrames(retained)
}

func (assembler *FrameAssembler) Stats() FrameAssemblerStats {
	assembler.mutex.Lock()
	defer assembler.mutex.Unlock()
	result := assembler.stats
	result.RetainedFrames = len(assembler.pending)
	for _, frame := range assembler.pending {
		if frame.complete == nil {
			result.PendingFrames++
		}
	}
	return result
}

// Close releases any incomplete frame chain still retained when its media
// source ends. It is safe to call more than once.
func (assembler *FrameAssembler) Close() {
	assembler.mutex.Lock()
	defer assembler.mutex.Unlock()
	assembler.clearPending()
	assembler.lossActive = false
	assembler.lossStartNanos = 0
	assembler.waitingKeyframe = false
	assembler.updateRetainedCounter()
}

func (assembler *FrameAssembler) malformed(detail string) (AssemblyResult, error) {
	assembler.clearPending()
	assembler.lossActive = false
	assembler.lossStartNanos = 0
	assembler.waitingKeyframe = assembler.hasStream
	assembler.stats.Malformed++
	return AssemblyResult{}, fmt.Errorf("%w: %s", errFrameAssembly, detail)
}

var (
	errMediaReceiver = errors.New("AV1 media receiver failed")
	receiveEpoch     = time.Now()
)

func readTestAV1Track(
	remote *webrtc.TrackRemote,
	receiver *webrtc.RTPReceiver,
	recoveryWindow time.Duration,
	counters *RecoveryCounters,
	onFrame func(AssembledFrame),
	onKeyframeRequired func(streamID uint64),
) error {
	if remote == nil || receiver == nil || counters == nil || onFrame == nil ||
		onKeyframeRequired == nil || recoveryWindow < 0 {
		return fmt.Errorf("%w: missing track, receiver, counter, or callback", errMediaReceiver)
	}
	codec := remote.Codec()
	if !strings.EqualFold(codec.MimeType, webrtc.MimeTypeAV1) || codec.ClockRate != 90_000 {
		return fmt.Errorf(
			"%w: unexpected codec %s/%d", errMediaReceiver, codec.MimeType, codec.ClockRate,
		)
	}
	extensionID := 0
	for _, extension := range receiver.GetParameters().HeaderExtensions {
		if extension.URI == frameMetadataURI {
			if extensionID != 0 {
				return fmt.Errorf("%w: duplicate metadata extensions", errMediaReceiver)
			}
			extensionID = extension.ID
		}
	}
	if extensionID <= 0 || extensionID > 255 {
		return fmt.Errorf("%w: metadata extension not negotiated", errMediaReceiver)
	}
	assembler, err := NewFrameAssembler(FrameAssemblerConfig{
		ExtensionID: uint8(extensionID), RecoveryWindow: recoveryWindow, Counters: counters,
	})
	if err != nil {
		return fmt.Errorf("%w: %v", errMediaReceiver, err)
	}
	inspectorStop := make(chan struct{})
	inspectorDone := make(chan struct{})
	go func() {
		defer close(inspectorDone)
		runFrameAssemblyExpiryInspector(
			inspectorStop,
			nackInspectionInterval,
			func() uint64 { return uint64(time.Since(receiveEpoch)) },
			assembler,
			onKeyframeRequired,
		)
	}()
	defer func() {
		close(inspectorStop)
		<-inspectorDone
		assembler.Close()
	}()
	for {
		packet, _, err := remote.ReadRTP()
		if err != nil {
			return err
		}
		if packet.PayloadType != uint8(remote.PayloadType()) {
			return fmt.Errorf(
				"%w: payload type %d, want %d",
				errMediaReceiver,
				packet.PayloadType,
				remote.PayloadType(),
			)
		}
		result, err := assembler.Push(packet, uint64(time.Since(receiveEpoch)))
		if err != nil {
			return fmt.Errorf("%w: %v", errMediaReceiver, err)
		}
		for _, frame := range result.Frames {
			onFrame(frame)
		}
		if result.KeyframeRequired {
			onKeyframeRequired(result.KeyframeStreamID)
		}
	}
}

func runFrameAssemblyExpiryInspector(
	stop <-chan struct{},
	interval time.Duration,
	now func() uint64,
	assembler *FrameAssembler,
	onKeyframeRequired func(uint64),
) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			result := assembler.Inspect(now())
			if result.KeyframeRequired {
				onKeyframeRequired(result.KeyframeStreamID)
			}
		case <-stop:
			return
		}
	}
}

func newTestViewerAPI(config PeerConfig) (*webrtc.API, *peerAPIResources, error) {
	return newPeerAPI(config)
}

func createTestViewerDataChannels(peer *webrtc.PeerConnection) (sessionDataChannels, error) {
	ordered := false
	maxRetransmits := uint16(0)
	input, err := peer.CreateDataChannel(inputChannelLabel, &webrtc.DataChannelInit{
		Ordered:        &ordered,
		MaxRetransmits: &maxRetransmits,
	})
	if err != nil {
		return sessionDataChannels{}, fmt.Errorf("create input DataChannel: %w", err)
	}
	input.SetBufferedAmountLowThreshold(inputBufferedAmountLowThreshold)
	control, err := peer.CreateDataChannel(controlChannelLabel, nil)
	if err != nil {
		_ = input.Close()
		return sessionDataChannels{}, fmt.Errorf("create control DataChannel: %w", err)
	}
	return sessionDataChannels{input: input, control: control}, nil
}

type sessionDataChannels struct {
	input   *webrtc.DataChannel
	control *webrtc.DataChannel
}

func newTestViewerSession(
	configuration SessionConfiguration,
	callbacks SessionCallbacks,
	onFrame func(AssembledFrame),
) (*Session, error) {
	if err := validateSessionConfiguration(configuration); err != nil {
		return nil, err
	}
	session, err := createSession(configuration, callbacks)
	if err != nil {
		return nil, err
	}
	failed := true
	defer func() {
		if failed {
			_ = session.Close()
		}
	}()

	channels, err := createTestViewerDataChannels(session.peer)
	if err != nil {
		return nil, err
	}
	if err := session.attachDataChannel(channels.input); err != nil {
		return nil, err
	}
	if err := session.attachDataChannel(channels.control); err != nil {
		return nil, err
	}
	if _, err := session.peer.AddTransceiverFromKind(
		webrtc.RTPCodecTypeVideo,
		webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionRecvonly},
	); err != nil {
		return nil, fmt.Errorf("add test AV1 receiver: %w", err)
	}
	session.peer.OnTrack(func(remote *webrtc.TrackRemote, receiver *webrtc.RTPReceiver) {
		go func() {
			window := time.Duration(0)
			if session.config.Recovery == RecoveryNACKRTX {
				window = session.config.RTXMaxAge
			}
			err := readTestAV1Track(
				remote,
				receiver,
				window,
				session.apiResources.counters,
				func(frame AssembledFrame) {
					if onFrame != nil {
						onFrame(frame)
					}
				},
				func(streamID uint64) { session.emitRecoveryKeyframe(streamID) },
			)
			if err != nil && !errors.Is(err, io.ErrClosedPipe) &&
				!session.remoteClosureExpected() {
				session.fail(err)
			}
		}()
	})
	offer, err := gatherPeerDescription(session.peer, true)
	if err != nil {
		return nil, err
	}
	if configuration.Recovery == RecoveryNACKRTX {
		offer, err = advertiseRTXTime(offer, configuration.RTXMaxAge)
		if err != nil {
			return nil, err
		}
	}
	signalConnection, err := connectSignalTCP(
		configuration.LocalIP, configuration.RemoteIP, configuration.SignalPort,
	)
	if err != nil {
		return nil, err
	}
	defer signalConnection.Close()
	answer, err := exchangeOffer(signalConnection, offer)
	if err != nil {
		return nil, err
	}
	engineAnswer, err := preparePionRemoteDescription(
		answer,
		configuration.RTXMaxAge,
		configuration.Recovery == RecoveryNACKRTX,
	)
	if err != nil {
		return nil, fmt.Errorf("validate host answer: %w", err)
	}
	if err := session.peer.SetRemoteDescription(engineAnswer); err != nil {
		return nil, fmt.Errorf("set host answer: %w", err)
	}
	session.mutex.Lock()
	session.mediaReady = true
	session.mutex.Unlock()
	session.markSignalingComplete()
	failed = false
	return session, nil
}

func normalizedAV1(t *testing.T, payloads [][]byte) []byte {
	t.Helper()
	depacketizer := &codecs.AV1Depacketizer{}
	var result []byte
	for _, payload := range payloads {
		chunk, err := depacketizer.Unmarshal(payload)
		if err != nil {
			t.Fatal(err)
		}
		result = append(result, chunk...)
	}
	return result
}
