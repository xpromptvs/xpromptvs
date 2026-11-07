package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/pion/logging"
	"github.com/pion/transport/v4"
	"github.com/pion/transport/v4/vnet"
	"github.com/pion/webrtc/v4"
)

type recoveryVNetPairConfig struct {
	Recovery   RecoveryMode
	RTXMaxAge  time.Duration
	Profile    *recoveryMatrixProfile
	Controller *recoveryImpairmentController
	OnRecovery func()
}

const (
	matrixSetupRateBitsPerSecond            = 1_000_000_000
	matrixSetupQueueBytes             int64 = 64 << 20
	matrixConservativeRTPPayloadBytes       = maximumRTPBytes - 128
)

// Pion vnet assigns MAC addresses from an unsynchronized package-global
// counter. Serialize only constructors that touch it; scenario runtime remains
// independent and concurrent.
var recoveryVNetConstructionMutex sync.Mutex

func newRecoveryVNetPairWithConfig(
	t *testing.T,
	config recoveryVNetPairConfig,
) (*recoveryVNetPair, error) {
	t.Helper()
	pair, err := createRecoveryVNetPair(config)
	if err != nil {
		return nil, err
	}
	pair.testing = t
	t.Cleanup(func() {
		if err := pair.Close(); err != nil {
			t.Errorf("close recovery pair: %v", err)
		}
	})
	return pair, nil
}

func createRecoveryVNetPair(config recoveryVNetPairConfig) (_ *recoveryVNetPair, resultError error) {
	minimumDelay := time.Duration(0)
	if config.Controller == nil && config.Profile != nil {
		minimumDelay = time.Duration(config.Profile.OneWayDelayMicroseconds) * time.Microsecond
	}
	recoveryVNetConstructionMutex.Lock()
	router, err := vnet.NewRouter(&vnet.RouterConfig{
		CIDR: "10.0.0.0/24", MinDelay: minimumDelay,
		LoggerFactory: logging.NewDefaultLoggerFactory(),
	})
	recoveryVNetConstructionMutex.Unlock()
	if err != nil {
		return nil, fmt.Errorf("create recovery vnet router: %w", err)
	}
	pair := &recoveryVNetPair{
		router: router, controller: config.Controller, onRecovery: config.OnRecovery,
		frames: make(chan recoveryVNetFrame, 256), errors: make(chan error, 32),
		requests: make(chan uint64, 256), receiverDone: make(chan struct{}),
	}
	defer func() {
		if resultError != nil {
			if err := pair.Close(); err != nil {
				resultError = errors.Join(resultError, fmt.Errorf("close recovery pair: %w", err))
			}
		}
	}()

	recoveryVNetConstructionMutex.Lock()
	pair.hostNet, err = vnet.NewNet(&vnet.NetConfig{StaticIPs: []string{vnetHostIP}})
	recoveryVNetConstructionMutex.Unlock()
	if err != nil {
		return nil, fmt.Errorf("create recovery host vnet: %w", err)
	}
	recoveryVNetConstructionMutex.Lock()
	pair.viewNet, err = vnet.NewNet(&vnet.NetConfig{StaticIPs: []string{vnetViewerIP}})
	recoveryVNetConstructionMutex.Unlock()
	if err != nil {
		return nil, fmt.Errorf("create recovery viewer vnet: %w", err)
	}
	var hostNIC vnet.NIC = pair.hostNet
	var viewerNIC vnet.NIC = pair.viewNet
	if config.Controller == nil && config.Profile != nil && config.Profile.BandwidthPermille > 0 {
		pair.hostTBF = vnet.NewTBFQueue(
			matrixSetupRateBitsPerSecond, 2*maximumRTPBytes, matrixSetupQueueBytes,
		)
		pair.hostQueue, err = vnet.NewQueue(pair.hostNet, pair.hostTBF)
		if err != nil {
			return nil, fmt.Errorf("create recovery host TBF queue: %w", err)
		}
		pair.viewTBF = vnet.NewTBFQueue(
			matrixSetupRateBitsPerSecond, 2*maximumRTPBytes, matrixSetupQueueBytes,
		)
		pair.viewQueue, err = vnet.NewQueue(pair.viewNet, pair.viewTBF)
		if err != nil {
			return nil, fmt.Errorf("create recovery viewer TBF queue: %w", err)
		}
		hostNIC = pair.hostQueue
		viewerNIC = pair.viewQueue
	}
	if err := router.AddNet(hostNIC); err != nil {
		return nil, fmt.Errorf("add recovery host vnet: %w", err)
	}
	if err := router.AddNet(viewerNIC); err != nil {
		return nil, fmt.Errorf("add recovery viewer vnet: %w", err)
	}
	if err := router.Start(); err != nil {
		return nil, fmt.Errorf("start recovery vnet router: %w", err)
	}

	var hostNetwork transport.Net = pair.hostNet
	var viewerNetwork transport.Net = pair.viewNet
	if config.Controller != nil {
		hostNetwork = config.Controller.WrapNet(matrixHost, hostNetwork)
		viewerNetwork = config.Controller.WrapNet(matrixViewer, viewerNetwork)
	}
	hostAPI, hostResources, err := newPeerAPI(PeerConfig{
		ICEPolicy: ICEPolicyStrict,
		LocalIP:   net.ParseIP(vnetHostIP), RemoteIP: net.ParseIP(vnetViewerIP),
		ICEPort: 5_700, SignalPort: 5_701, Recovery: config.Recovery,
		RTXMaxAge: config.RTXMaxAge, Network: hostNetwork,
	})
	if err != nil {
		return nil, fmt.Errorf("create recovery host API: %w", err)
	}
	pair.hostAPI = hostResources
	viewerAPI, viewerResources, err := newTestViewerAPI(PeerConfig{
		ICEPolicy: ICEPolicyStrict,
		LocalIP:   net.ParseIP(vnetViewerIP), RemoteIP: net.ParseIP(vnetHostIP),
		ICEPort: 5_702, SignalPort: 5_701, Recovery: config.Recovery,
		RTXMaxAge: config.RTXMaxAge, Network: viewerNetwork,
	})
	if err != nil {
		return nil, fmt.Errorf("create recovery viewer API: %w", err)
	}
	pair.viewAPI = viewerResources
	hostResources.SetRecoveryCallbacks(
		func(uint32) {
			hostResources.counters.addRecoveryKeyframeRequest()
			pair.signalRecoveryRequest(0)
		},
		pair.publishError,
		func() {},
	)
	viewerResources.SetRecoveryCallbacks(
		func(uint32) {
			viewerResources.counters.addRecoveryKeyframeRequest()
			pair.signalRecoveryRequest(0)
		},
		pair.publishError,
		func() {},
	)

	pair.host, err = hostAPI.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		return nil, fmt.Errorf("create recovery host peer: %w", err)
	}
	pair.viewer, err = viewerAPI.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		return nil, fmt.Errorf("create recovery viewer peer: %w", err)
	}
	pair.track = NewFrameTrack("video", "desktop")
	if _, err := pair.host.AddTrack(pair.track); err != nil {
		return nil, fmt.Errorf("add recovery frame track: %w", err)
	}
	if _, err := pair.viewer.AddTransceiverFromKind(
		webrtc.RTPCodecTypeVideo,
		webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionRecvonly},
	); err != nil {
		return nil, fmt.Errorf("add recovery receiver: %w", err)
	}
	pair.viewer.OnTrack(func(remote *webrtc.TrackRemote, receiver *webrtc.RTPReceiver) {
		window := time.Duration(0)
		if config.Recovery == RecoveryNACKRTX {
			window = config.RTXMaxAge
		}
		pair.receiverMutex.Lock()
		if pair.receiverClosing || pair.receiverStarted {
			pair.receiverMutex.Unlock()
			return
		}
		pair.receiverStarted = true
		receiverDone := pair.receiverDone
		pair.receiverMutex.Unlock()
		go func() {
			defer close(receiverDone)
			pair.publishError(readTestAV1Track(
				remote, receiver, window, viewerResources.counters,
				func(frame AssembledFrame) {
					pair.frames <- recoveryVNetFrame{Frame: frame, AssembledAt: time.Now()}
				},
				func(streamID uint64) {
					viewerResources.counters.addRecoveryKeyframeRequest()
					pair.signalRecoveryRequest(streamID)
				},
			))
		}()
	})

	setupContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	offer, err := gatherRecoveryDescription(setupContext, pair.viewer, true)
	if err != nil {
		return nil, err
	}
	if config.Recovery == RecoveryNACKRTX {
		offer, err = advertiseRTXTime(offer, config.RTXMaxAge)
		if err != nil {
			return nil, fmt.Errorf("advertise recovery offer RTX time: %w", err)
		}
	}
	hostOffer, err := preparePionRemoteDescription(offer, config.RTXMaxAge, false)
	if err != nil {
		return nil, fmt.Errorf("prepare recovery host offer: %w", err)
	}
	if err := pair.host.SetRemoteDescription(hostOffer); err != nil {
		return nil, fmt.Errorf("set recovery host remote offer: %w", err)
	}
	answer, err := gatherRecoveryDescription(setupContext, pair.host, false)
	if err != nil {
		return nil, err
	}
	if config.Recovery == RecoveryNACKRTX {
		answer, err = advertiseRTXTime(answer, config.RTXMaxAge)
		if err != nil {
			return nil, fmt.Errorf("advertise recovery answer RTX time: %w", err)
		}
	}
	viewerAnswer, err := preparePionRemoteDescription(
		answer, config.RTXMaxAge, config.Recovery == RecoveryNACKRTX,
	)
	if err != nil {
		return nil, fmt.Errorf("prepare recovery viewer answer: %w", err)
	}
	if err := pair.viewer.SetRemoteDescription(viewerAnswer); err != nil {
		return nil, fmt.Errorf("set recovery viewer remote answer: %w", err)
	}
	if err := waitForRecoveryPeerState(setupContext, pair.host, webrtc.PeerConnectionStateConnected); err != nil {
		return nil, err
	}
	if err := waitForRecoveryPeerState(setupContext, pair.viewer, webrtc.PeerConnectionStateConnected); err != nil {
		return nil, err
	}
	return pair, nil
}

func (pair *recoveryVNetPair) activateBandwidth(profile recoveryMatrixProfile, deltaBytes int) error {
	if profile.BandwidthPermille == 0 {
		return nil
	}
	if pair.controller != nil {
		if pair.controller.Snapshot().BandwidthQueueModel != recoveryBandwidthQueueModelVirtualFluid {
			return errors.New("controller-backed bandwidth profile has no virtual fluid queues")
		}
		return nil
	}
	if pair.hostTBF == nil || pair.viewTBF == nil {
		return errors.New("bandwidth profile has no virtual token-bucket queues")
	}
	rateBitsPerSecond := profile.NominalMediaBitsPerSecond * profile.BandwidthPermille / 1_000
	largestFrameBytes := deltaBytes * profile.KeyframeSizeMultiplier
	packetsPerFrame := (largestFrameBytes + matrixConservativeRTPPayloadBytes - 1) /
		matrixConservativeRTPPayloadBytes
	queueBytes := int64(packetsPerFrame * maximumRTPBytes * profile.QueueFrames)
	if rateBitsPerSecond <= 0 || queueBytes <= 0 {
		return errors.New("bandwidth profile resolved to a nonpositive rate or queue")
	}
	for _, queue := range []*vnet.TBFQueue{pair.hostTBF, pair.viewTBF} {
		queue.SetRate(rateBitsPerSecond)
		queue.SetBurst(2 * maximumRTPBytes)
		queue.SetSize(queueBytes)
	}
	return nil
}

func (pair *recoveryVNetPair) waitForBandwidthDrain(
	ctx context.Context,
	profile recoveryMatrixProfile,
	deltaBytes int,
) error {
	if profile.BandwidthPermille == 0 {
		return nil
	}
	if pair.controller != nil {
		return nil
	}
	rateBitsPerSecond := profile.NominalMediaBitsPerSecond * profile.BandwidthPermille / 1_000
	largestFrameBytes := deltaBytes * profile.KeyframeSizeMultiplier
	packetsPerFrame := (largestFrameBytes + matrixConservativeRTPPayloadBytes - 1) /
		matrixConservativeRTPPayloadBytes
	queueBytes := packetsPerFrame * maximumRTPBytes * profile.QueueFrames
	drain := 2 * time.Duration(int64(queueBytes)*8*int64(time.Second)/int64(rateBitsPerSecond))
	drain += 2*time.Duration(profile.OneWayDelayMicroseconds)*time.Microsecond +
		time.Duration(profile.MaxJitterMicroseconds)*time.Microsecond
	if drain < 10*time.Millisecond {
		drain = 10 * time.Millisecond
	}
	timer := time.NewTimer(drain)
	defer timer.Stop()
	select {
	case <-timer.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func gatherRecoveryDescription(
	ctx context.Context,
	peer *webrtc.PeerConnection,
	offer bool,
) (webrtc.SessionDescription, error) {
	var description webrtc.SessionDescription
	var err error
	if offer {
		description, err = peer.CreateOffer(nil)
	} else {
		description, err = peer.CreateAnswer(nil)
	}
	if err != nil {
		return webrtc.SessionDescription{}, fmt.Errorf("create recovery description: %w", err)
	}
	complete := webrtc.GatheringCompletePromise(peer)
	if err := peer.SetLocalDescription(description); err != nil {
		return webrtc.SessionDescription{}, fmt.Errorf("set recovery local description: %w", err)
	}
	select {
	case <-complete:
		return *peer.LocalDescription(), nil
	case <-ctx.Done():
		return webrtc.SessionDescription{}, fmt.Errorf("gather recovery ICE: %w", ctx.Err())
	}
}

func waitForRecoveryPeerState(
	ctx context.Context,
	peer *webrtc.PeerConnection,
	wanted webrtc.PeerConnectionState,
) error {
	ticker := time.NewTicker(5 * time.Millisecond)
	defer ticker.Stop()
	for {
		if peer.ConnectionState() == wanted {
			return nil
		}
		select {
		case <-ticker.C:
		case <-ctx.Done():
			return fmt.Errorf("recovery peer state = %s, want %s: %w", peer.ConnectionState(), wanted, ctx.Err())
		}
	}
}

func (pair *recoveryVNetPair) signalRecoveryRequest(streamID uint64) {
	if pair.onRecovery != nil {
		pair.onRecovery()
	}
	select {
	case pair.requests <- streamID:
	default:
		pair.publishError(errors.New("recovery request channel overflow"))
	}
}

func (pair *recoveryVNetPair) publishError(err error) {
	if err == nil {
		return
	}
	select {
	case pair.errors <- err:
	default:
	}
}

type recoveryMatrixScenarioHooks struct {
	AfterMeasuredFrame func(index int, requestKeyframe func())
}

func runRecoveryMatrixScenario(
	ctx context.Context,
	profile recoveryMatrixProfile,
) recoveryMatrixScenarioResult {
	return runRecoveryMatrixScenarioWithHooks(ctx, profile, recoveryMatrixScenarioHooks{})
}

func runRecoveryMatrixScenarioWithHooks(
	parent context.Context,
	profile recoveryMatrixProfile,
	hooks recoveryMatrixScenarioHooks,
) recoveryMatrixScenarioResult {
	result := recoveryMatrixScenarioResult{
		Name: profile.Name, ExpectedOutcome: profile.ExpectedOutcome,
		Profile: cloneRecoveryMatrixProfile(profile),
	}
	if profile.Seed != nil {
		result.Seed = *profile.Seed
	}
	watchdog := time.Duration(profile.WatchdogMilliseconds) * time.Millisecond
	ctx, cancel := context.WithTimeout(parent, watchdog)
	defer cancel()
	seed := int64(0)
	if profile.Seed != nil {
		seed = *profile.Seed
	}
	controller, err := NewRecoveryImpairmentController(RecoveryImpairmentConfiguration{
		Profile: profile,
		Seed:    seed,
	})
	if err != nil {
		result.Error = fmt.Sprintf("create impairment controller: %v", err)
		return evaluateRecoveryMatrixResult(result)
	}
	// One controller wraps both in-process peers. Count delivery when the peer
	// reads each datagram; production controllers wrap only one peer and meter
	// their successful writes instead.
	controller.meterWrites = false
	var pendingKeyframe atomic.Bool
	var recoveryEpisodeActive atomic.Bool
	pair, err := createRecoveryVNetPair(recoveryVNetPairConfig{
		Recovery:  RecoveryNACKRTX,
		RTXMaxAge: time.Duration(profile.RTXMaxAgeMilliseconds) * time.Millisecond,
		Profile:   &profile, Controller: controller,
		OnRecovery: func() {
			recoveryEpisodeActive.Store(true)
			pendingKeyframe.Store(true)
		},
	})
	if err != nil {
		_ = controller.Close()
		result.Error = err.Error()
		return evaluateRecoveryMatrixResult(result)
	}
	defer pair.Close()

	deltaBytes := (profile.NominalMediaBitsPerSecond + profile.FPS*8 - 1) / (profile.FPS * 8)
	keyframeBytes := deltaBytes * profile.KeyframeSizeMultiplier
	frameInterval := time.Second / time.Duration(profile.FPS)
	for index := 1; index <= profile.WarmupFrames; index++ {
		frameID := uint64(index)
		keyframe := index == 1
		bytes := deltaBytes
		if keyframe {
			bytes = keyframeBytes
			result.Metrics.KeyframeFrameIDs = append(result.Metrics.KeyframeFrameIDs, frameID)
		}
		if err := pair.writeFrame(frameID, keyframe, bytes); err != nil {
			result.Error = fmt.Sprintf("write warm-up frame %d: %v", frameID, err)
			pair.Close()
			return finishRecoveryMatrixScenario(result, pair, controller)
		}
		if _, err := pair.receiveFrame(ctx); err != nil {
			result.Error = fmt.Sprintf("receive warm-up frame %d: %v", frameID, err)
			pair.Close()
			return finishRecoveryMatrixScenario(result, pair, controller)
		}
	}
	if err := pair.activateBandwidth(profile, deltaBytes); err != nil {
		result.Error = fmt.Sprintf("activate bandwidth profile: %v", err)
		pair.Close()
		return finishRecoveryMatrixScenario(result, pair, controller)
	}
	if err := controller.Activate(); err != nil {
		result.Error = fmt.Sprintf("activate impairment controller: %v", err)
		pair.Close()
		return finishRecoveryMatrixScenario(result, pair, controller)
	}

	var submissionTimes sync.Map
	var keyframeMutex sync.Mutex
	var measuredKeyframes []uint64
	var submitted atomic.Uint64
	senderDone := make(chan error, 1)
	go func() {
		start := time.Now()
		for index := 1; index <= profile.MeasuredFrames; index++ {
			target := start.Add(time.Duration(index-1) * frameInterval)
			if err := waitRecoveryMatrixDeadline(ctx, target); err != nil {
				senderDone <- err
				return
			}
			frameID := uint64(profile.WarmupFrames + index)
			keyframe := pendingKeyframe.Swap(false)
			bytes := deltaBytes
			if keyframe {
				bytes = keyframeBytes
				keyframeMutex.Lock()
				measuredKeyframes = append(measuredKeyframes, frameID)
				keyframeMutex.Unlock()
			}
			submittedAt := time.Now()
			submissionTimes.Store(frameID, submittedAt)
			if err := pair.writeFrame(frameID, keyframe, bytes); err != nil {
				senderDone <- fmt.Errorf("write measured frame %d: %w", frameID, err)
				return
			}
			submitted.Add(1)
			if hooks.AfterMeasuredFrame != nil {
				hooks.AfterMeasuredFrame(index, func() { pendingKeyframe.Store(true) })
			}
		}
		senderDone <- nil
	}()

	var submissionToAssembly []time.Duration
	var recoveryResolution []time.Duration
	var interarrival []time.Duration
	var previousCompletion time.Time
	var recoveryStarted time.Time
	senderFinished := false
	var senderError error
	var graceTimer *time.Timer
	var grace <-chan time.Time
	for {
		if senderFinished && result.Metrics.FramesCompleted >= uint64(profile.MeasuredFrames) {
			break
		}
		select {
		case received := <-pair.frames:
			frame := received.Frame
			if frame.Metadata.FrameID <= uint64(profile.WarmupFrames) {
				continue
			}
			completedAt := received.AssembledAt
			result.Metrics.FramesCompleted++
			result.Metrics.CompletedFrameIDs = append(result.Metrics.CompletedFrameIDs, frame.Metadata.FrameID)
			if submittedAt, ok := submissionTimes.Load(frame.Metadata.FrameID); ok {
				submissionToAssembly = append(submissionToAssembly, completedAt.Sub(submittedAt.(time.Time)))
			}
			if !previousCompletion.IsZero() {
				gap := completedAt.Sub(previousCompletion)
				interarrival = append(interarrival, gap)
				if milliseconds := float64(gap) / float64(time.Millisecond); milliseconds > result.Metrics.LongestFreezeProxyMilliseconds {
					result.Metrics.LongestFreezeProxyMilliseconds = milliseconds
				}
			}
			previousCompletion = completedAt
			if recoveryMatrixAssemblyResumesRecovery(recoveryStarted, completedAt) {
				recoveryResolution = append(recoveryResolution, completedAt.Sub(recoveryStarted))
				result.Metrics.FramesResumedAfterRecovery++
				recoveryStarted = time.Time{}
				recoveryEpisodeActive.Store(false)
			}
		case attempt := <-controller.nackAttempts:
			if recoveryStarted.IsZero() {
				recoveryStarted = attempt.ObservedAt
				recoveryEpisodeActive.Store(true)
			}
		case err := <-pair.errors:
			if err != nil {
				result.Error = fmt.Sprintf("receive measured stream: %v", err)
				goto measuredDone
			}
		case senderError = <-senderDone:
			senderFinished = true
			senderDone = nil
			if senderError != nil {
				result.Error = senderError.Error()
				goto measuredDone
			}
			graceDuration := 2 * time.Duration(profile.RTXMaxAgeMilliseconds) * time.Millisecond
			if graceDuration < 250*time.Millisecond {
				graceDuration = 250 * time.Millisecond
			}
			graceTimer = time.NewTimer(graceDuration)
			grace = graceTimer.C
		case <-grace:
			goto measuredDone
		case <-ctx.Done():
			result.Error = fmt.Sprintf("scenario watchdog: %v", ctx.Err())
			goto measuredDone
		}
	}

measuredDone:
	if graceTimer != nil && !graceTimer.Stop() {
		select {
		case <-graceTimer.C:
		default:
		}
	}
	if !senderFinished {
		cancel()
		if err := <-senderDone; err != nil && result.Error == "" {
			result.Error = err.Error()
		}
	}
	result.Metrics.FramesSubmitted = submitted.Load()
	keyframeMutex.Lock()
	result.Metrics.KeyframeFrameIDs = append(result.Metrics.KeyframeFrameIDs, measuredKeyframes...)
	keyframeMutex.Unlock()
	if len(measuredKeyframes) > 0 && keyframeBytes > deltaBytes {
		result.Metrics.SyntheticKeyframeExcessBytes = uint64(len(measuredKeyframes) * (keyframeBytes - deltaBytes))
	}
	if drainErr := pair.drain(ctx); drainErr != nil && result.Error == "" {
		result.Error = fmt.Sprintf("drain impairment scheduler: %v", drainErr)
	}
	if drainErr := pair.waitForBandwidthDrain(ctx, profile, deltaBytes); drainErr != nil && result.Error == "" {
		result.Error = fmt.Sprintf("drain bandwidth queues: %v", drainErr)
	}
	if result.Error == "" && profile.BandwidthPermille > 0 && !recoveryStarted.IsZero() {
		tailFrameID := uint64(profile.WarmupFrames + profile.MeasuredFrames + 1)
		if err := pair.writeFrame(tailFrameID, true, keyframeBytes); err != nil {
			result.Error = fmt.Sprintf("write recovery-tail keyframe %d: %v", tailFrameID, err)
		} else {
			result.Metrics.KeyframeFrameIDs = append(result.Metrics.KeyframeFrameIDs, tailFrameID)
			result.Metrics.SyntheticKeyframeExcessBytes += uint64(keyframeBytes - deltaBytes)
			if err := pair.drain(ctx); err != nil {
				result.Error = fmt.Sprintf("drain recovery-tail scheduler: %v", err)
			} else if err := pair.waitForBandwidthDrain(ctx, profile, deltaBytes); err != nil {
				result.Error = fmt.Sprintf("drain recovery-tail bandwidth queue: %v", err)
			} else {
				for result.Error == "" {
					frame, err := pair.receiveFrame(ctx)
					if err != nil {
						result.Error = fmt.Sprintf("receive recovery-tail keyframe: %v", err)
						break
					}
					if frame.Metadata.FrameID == tailFrameID {
						recoveredAt := time.Now()
						recoveryResolution = append(recoveryResolution, recoveredAt.Sub(recoveryStarted))
						result.Metrics.FramesResumedAfterRecovery++
						break
					}
				}
			}
		}
	}
	result.Metrics.SubmissionToAssembly = summarizeRecoveryMatrixDurations(submissionToAssembly)
	result.Metrics.RecoveryResolution = summarizeRecoveryMatrixDurations(recoveryResolution)
	result.Metrics.CompletedFrameInterarrival = summarizeRecoveryMatrixDurations(interarrival)
	pair.Close()
	return finishRecoveryMatrixScenario(result, pair, controller)
}

func recoveryMatrixAssemblyResumesRecovery(recoveryStarted, assembledAt time.Time) bool {
	return !recoveryStarted.IsZero() && assembledAt.After(recoveryStarted)
}

func waitRecoveryMatrixDeadline(ctx context.Context, deadline time.Time) error {
	wait := time.Until(deadline)
	if wait <= 0 {
		return nil
	}
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case <-timer.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func finishRecoveryMatrixScenario(
	result recoveryMatrixScenarioResult,
	pair *recoveryVNetPair,
	controller *recoveryImpairmentController,
) recoveryMatrixScenarioResult {
	closeErr := pair.Close()
	if closeErr != nil {
		message := fmt.Sprintf("close recovery pair: %v", closeErr)
		if result.Error == "" {
			result.Error = message
		} else {
			result.Error += "; " + message
		}
	}
	controller.ReconcileQueueLossAfterDrain()
	result.Metrics.Recovery = pair.recoverySnapshot()
	result.Metrics.FramesExpired = result.Metrics.Recovery.IncompleteFramesExpired
	result.Metrics.FramesAbandoned = result.Metrics.Recovery.DependentFramesAbandoned
	result.Metrics.ResponderCache = addResponderCacheSnapshots(
		pair.hostAPI.ResponderCacheSnapshot(), pair.viewAPI.ResponderCacheSnapshot(),
	)
	result.Metrics.Impairment = controller.Snapshot()
	originalBytes := result.Metrics.Impairment.AdmittedToVNet[matrixPacketOriginal].Bytes
	if originalBytes > 0 {
		result.Metrics.RTXToOriginalByteRatio = float64(
			result.Metrics.Impairment.AdmittedToVNet[matrixPacketRTX].Bytes,
		) / float64(originalBytes)
	}
	result.Metrics.ShutdownComplete = closeErr == nil &&
		result.Metrics.Recovery.RetainedFramesCurrent == 0 &&
		result.Metrics.ResponderCache.PacketsCurrent == 0 &&
		result.Metrics.ResponderCache.BytesCurrent == 0 &&
		result.Metrics.Impairment.ScheduledBytesCurrent == 0
	return evaluateRecoveryMatrixResult(result)
}

func addResponderCacheSnapshots(left, right ResponderCacheSnapshot) ResponderCacheSnapshot {
	return ResponderCacheSnapshot{
		PacketsCurrent: left.PacketsCurrent + right.PacketsCurrent,
		PacketsPeak:    left.PacketsPeak + right.PacketsPeak,
		BytesCurrent:   left.BytesCurrent + right.BytesCurrent,
		BytesPeak:      left.BytesPeak + right.BytesPeak,
	}
}

func TestRecoveryVNetBandwidthShaperSelection(t *testing.T) {
	profile := mustRecoveryMatrixProfile(t, "bandwidth-0.9x-q1")
	deltaBytes := (profile.NominalMediaBitsPerSecond + profile.FPS*8 - 1) /
		(profile.FPS * 8)

	t.Run("controller is sole shaper", func(t *testing.T) {
		controller, err := NewRecoveryImpairmentController(RecoveryImpairmentConfiguration{
			Profile: profile,
			Seed:    1_741,
		})
		if err != nil {
			t.Fatal(err)
		}
		pair, err := newRecoveryVNetPairWithConfig(t, recoveryVNetPairConfig{
			Recovery:  RecoveryNACKRTX,
			RTXMaxAge: time.Duration(profile.RTXMaxAgeMilliseconds) * time.Millisecond,
			Profile:   &profile, Controller: controller,
		})
		if err != nil {
			t.Fatal(err)
		}
		if pair.hostTBF != nil || pair.viewTBF != nil || pair.hostQueue != nil || pair.viewQueue != nil {
			t.Fatalf("controller-backed pair also installed native TBF queues: %#v", pair)
		}
		if err := pair.activateBandwidth(profile, deltaBytes); err != nil {
			t.Fatalf("activate controller-backed bandwidth: %v", err)
		}
		if got := controller.Snapshot().BandwidthQueueModel; got != recoveryBandwidthQueueModelVirtualFluid {
			t.Fatalf("controller queue model = %q", got)
		}
	})

	t.Run("standalone native TBF remains available", func(t *testing.T) {
		pair, err := newRecoveryVNetPairWithConfig(t, recoveryVNetPairConfig{
			Recovery:  RecoveryNACKRTX,
			RTXMaxAge: time.Duration(profile.RTXMaxAgeMilliseconds) * time.Millisecond,
			Profile:   &profile,
		})
		if err != nil {
			t.Fatal(err)
		}
		if pair.hostTBF == nil || pair.viewTBF == nil || pair.hostQueue == nil || pair.viewQueue == nil {
			t.Fatalf("standalone bandwidth pair lacks native TBF queues: %#v", pair)
		}
		if err := pair.activateBandwidth(profile, deltaBytes); err != nil {
			t.Fatalf("activate standalone bandwidth: %v", err)
		}
	})
}

func TestRecoveryMatrixHarnessRunsPacedCleanStream(t *testing.T) {
	profile := mustRecoveryMatrixProfile(t, "clean")
	profile.WarmupFrames = 2
	profile.MeasuredFrames = 6
	result := runRecoveryMatrixScenario(context.Background(), profile)
	recoveryActivity := result.Metrics.Recovery
	recoveryActivity.ResponderCacheEvictions = 0
	if result.Status != matrixStatusPass || result.Metrics.FramesSubmitted != 6 ||
		result.Metrics.FramesCompleted != 6 || recoveryActivity != (RecoverySnapshot{}) {
		t.Fatalf("clean result = %#v", result)
	}
	if result.Metrics.SubmissionToAssembly.SampleCount != 6 {
		t.Fatalf("latency samples = %#v", result.Metrics.SubmissionToAssembly)
	}
}

func TestRecoveryMatrixHarnessRecoveryCallbackForcesOnlyNextFrameKeyframe(t *testing.T) {
	profile := mustRecoveryMatrixProfile(t, "clean")
	profile.WarmupFrames = 2
	profile.MeasuredFrames = 7
	result := runRecoveryMatrixScenarioWithHooks(
		context.Background(), profile,
		recoveryMatrixScenarioHooks{
			AfterMeasuredFrame: func(index int, requestKeyframe func()) {
				if index == 3 {
					requestKeyframe()
				}
			},
		},
	)
	if result.Status != matrixStatusPass {
		t.Fatalf("scenario = %#v", result)
	}
	if want := []uint64{1, 6}; !slices.Equal(result.Metrics.KeyframeFrameIDs, want) {
		t.Fatalf("keyframes = %v, want %v", result.Metrics.KeyframeFrameIDs, want)
	}
}

func TestFinishRecoveryMatrixScenarioReconcilesMediaUndeliveredAtShutdown(t *testing.T) {
	profile := mustRecoveryMatrixProfile(t, "clean")
	controller := newRecoveryImpairmentController(profile)
	pair, err := createRecoveryVNetPair(recoveryVNetPairConfig{
		Recovery: RecoveryNACKRTX, RTXMaxAge: 30 * time.Millisecond,
		Profile: &profile, Controller: controller,
	})
	if err != nil {
		_ = controller.Close()
		t.Fatal(err)
	}
	controller.Activate()
	controller.recordAdmitted(recoveryDatagramClassification{
		Endpoint: matrixHost, Class: matrixPacketRTX, Bytes: 1_200,
	})
	pair.Close()

	result := finishRecoveryMatrixScenario(recoveryMatrixScenarioResult{
		Name: profile.Name, ExpectedOutcome: profile.ExpectedOutcome, Profile: profile,
	}, pair, controller)
	if result.Metrics.Impairment.OutstandingMediaBytesCurrent != 0 {
		t.Fatalf(
			"outstanding media bytes = %d",
			result.Metrics.Impairment.OutstandingMediaBytesCurrent,
		)
	}
	if dropped := result.Metrics.Impairment.EffectiveQueueDropped[matrixPacketRTX]; dropped != (recoveryPacketTotals{Packets: 1, Bytes: 1_200}) {
		t.Fatalf("shutdown queue loss = %#v", dropped)
	}
}

func TestFinishRecoveryMatrixScenarioRejectsTeardownFailure(t *testing.T) {
	profile := mustRecoveryMatrixProfile(t, "clean")
	controller := newRecoveryImpairmentController(profile)
	pair, err := createRecoveryVNetPair(recoveryVNetPairConfig{
		Recovery: RecoveryNACKRTX, RTXMaxAge: 30 * time.Millisecond,
		Profile: &profile, Controller: controller,
	})
	if err != nil {
		_ = controller.Close()
		t.Fatal(err)
	}
	controller.mu.Lock()
	controller.asyncError = errors.New("forced teardown failure")
	controller.mu.Unlock()

	result := finishRecoveryMatrixScenario(recoveryMatrixScenarioResult{
		Name: profile.Name, ExpectedOutcome: profile.ExpectedOutcome, Profile: profile,
	}, pair, controller)
	if result.Metrics.ShutdownComplete || result.Status != matrixStatusInvalid ||
		!strings.Contains(result.Error, "forced teardown failure") {
		t.Fatalf(
			"teardown failure was certified: shutdown=%t status=%s error=%q",
			result.Metrics.ShutdownComplete, result.Status, result.Error,
		)
	}
}

func TestRecoveryMatrixHarnessRetriesLostRecoveryKeyframe(t *testing.T) {
	catalog, err := loadRecoveryMatrixCatalog(recoveryMatrixCatalogJSON)
	if err != nil {
		t.Fatal(err)
	}
	profiles, err := resolvedRecoveryMatrixProfiles(
		catalog, matrixTierExtended, "moderate-wan-seed-65537", nil,
	)
	if err != nil || len(profiles) != 1 {
		t.Fatalf("profile selection = %#v, %v", profiles, err)
	}

	result := runRecoveryMatrixScenario(t.Context(), profiles[0])
	if result.Status != matrixStatusPass || result.Metrics.FramesCompleted == 0 ||
		result.Metrics.FramesResumedAfterRecovery == 0 ||
		len(result.Metrics.KeyframeFrameIDs) < 3 {
		t.Fatalf(
			"lost recovery keyframe did not retry: status=%s completed=%d resumed=%d requests=%d keyframes=%v error=%s",
			result.Status,
			result.Metrics.FramesCompleted,
			result.Metrics.FramesResumedAfterRecovery,
			result.Metrics.Recovery.RecoveryKeyframeRequests,
			result.Metrics.KeyframeFrameIDs,
			result.Error,
		)
	}
}

func TestRecoveryMatrixRecoveryProgressUsesAssemblyTime(t *testing.T) {
	recoveryStarted := time.Unix(4_000, 0)
	if recoveryMatrixAssemblyResumesRecovery(
		recoveryStarted, recoveryStarted.Add(-time.Nanosecond),
	) {
		t.Fatal("a frame assembled before recovery began counted as resumed progress")
	}
	if !recoveryMatrixAssemblyResumesRecovery(
		recoveryStarted, recoveryStarted.Add(time.Nanosecond),
	) {
		t.Fatal("a frame assembled after recovery began did not count as resumed progress")
	}
}

func mustRecoveryMatrixProfile(t *testing.T, name string) recoveryMatrixProfile {
	t.Helper()
	catalog, err := loadRecoveryMatrixCatalog(recoveryMatrixCatalogJSON)
	if err != nil {
		t.Fatal(err)
	}
	profiles, err := resolvedRecoveryMatrixProfiles(catalog, matrixTierFast, name, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(profiles) != 1 {
		t.Fatalf("profile %q count = %d", name, len(profiles))
	}
	return profiles[0]
}
