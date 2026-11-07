package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"net"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestSessionCreateReadySendAndClose(t *testing.T) {
	inputAtHost := make(chan []byte, 1)
	inputAtViewer := make(chan []byte, 1)
	controlAtHost := make(chan []byte, 1)
	videoAtViewer := make(chan AssembledFrame, 1)
	host, viewer := startSessionPairWithFrameCallback(t, SessionCallbacks{
		OnMessage: func(channel ChannelKind, data []byte) {
			if channel == ChannelInput {
				inputAtHost <- data
			} else {
				controlAtHost <- data
			}
		},
	}, SessionCallbacks{
		OnMessage: func(channel ChannelKind, data []byte) {
			if channel == ChannelInput {
				inputAtViewer <- data
			}
		},
	}, func(frame AssembledFrame) { videoAtViewer <- frame })
	defer host.Close()
	defer viewer.Close()
	if err := host.WaitReady(5 * time.Second); err != nil {
		t.Fatal(err)
	}
	if err := viewer.WaitReady(5 * time.Second); err != nil {
		t.Fatal(err)
	}

	pointer := testWireMessage(wireKindPointer, 29)
	if disposition, err := viewer.SendInput(pointer); err != nil || disposition != SendDispositionSent {
		t.Fatalf("viewer input disposition = %d, error = %v", disposition, err)
	}
	requireBytes(t, inputAtHost, pointer)

	acknowledgment := testWireMessage(wireKindInputAcknowledgment, 16)
	if disposition, err := host.SendInput(acknowledgment); err != nil || disposition != SendDispositionSent {
		t.Fatalf("host ack disposition = %d, error = %v", disposition, err)
	}
	requireBytes(t, inputAtViewer, acknowledgment)

	keyframe := testWireMessage(wireKindKeyframe, 16)
	if err := viewer.SendControl(keyframe); err != nil {
		t.Fatal(err)
	}
	requireBytes(t, controlAtHost, keyframe)

	measurementStart := testWireMessage(wireKindMeasurementStart, 16)
	if err := viewer.SendControl(measurementStart); err != nil {
		t.Fatal(err)
	}
	requireBytes(t, controlAtHost, measurementStart)
	measurementAcknowledgment := testWireMessage(wireKindMeasurementStartAcknowledgment, 16)
	if disposition, err := host.SendInput(measurementAcknowledgment); err != nil || disposition != SendDispositionSent {
		t.Fatalf("measurement acknowledgment disposition = %d, error = %v", disposition, err)
	}
	requireBytes(t, inputAtViewer, measurementAcknowledgment)

	outbound := OutboundFrame{
		StreamID: 51, FrameID: 2, InputSequence: 3,
		HostProcessingNanos: 4, EncodeNanos: 2,
		Keyframe: true, Dependency: l1t1Dependency(true), Data: testAV1AccessUnit(2_000),
	}
	if err := host.SendVideo(outbound); err != nil {
		t.Fatal(err)
	}
	select {
	case inbound := <-videoAtViewer:
		if inbound.Metadata.FrameID != outbound.FrameID ||
			!bytes.Equal(inbound.Data, outbound.Data[2:]) {
			t.Fatalf("received video = %#v", inbound)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for session video")
	}

	for name, session := range map[string]*Session{"host": host, "test-viewer": viewer} {
		stats := session.Stats()
		if !stats.Ready || stats.SelectedCandidate.Protocol != "udp" ||
			stats.SelectedCandidate.LocalAddress != "127.0.0.1" ||
			stats.SelectedCandidate.RemoteAddress != "127.0.0.1" ||
			stats.JitterBufferMilliseconds != 0 ||
			stats.FrameAssemblyCapacity != defaultRecoveryFrameLimit ||
			!stats.NACK || !stats.RTX || stats.FEC {
			t.Fatalf("%s stats = %#v", name, stats)
		}
		if !slices.Equal(stats.HeaderExtensionURIs, []string{
			frameMetadataURI, playoutDelayURI, dependencyDescriptorURI,
		}) ||
			!slices.Equal(stats.RTCPFeedback, []string{"nack", "nack pli"}) {
			t.Fatalf("%s negotiated video stats = %#v", name, stats)
		}
		encoded, err := json.Marshal(stats)
		if err != nil || !json.Valid(encoded) {
			t.Fatalf("%s stats JSON = %q, error = %v", name, encoded, err)
		}
	}

	if err := viewer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := viewer.Close(); err != nil {
		t.Fatalf("second close failed: %v", err)
	}
	if _, err := viewer.SendInput(pointer); err == nil {
		t.Fatal("send after close unexpectedly succeeded")
	}
}

func TestRecoveryTraceHooksSessionThreadsItsRecorder(t *testing.T) {
	host, viewer := startSessionPairConfigured(
		t, SessionCallbacks{}, SessionCallbacks{}, true,
	)
	defer host.Close()
	defer viewer.Close()
	if err := host.WaitReady(5 * time.Second); err != nil {
		t.Fatal(err)
	}
	if err := viewer.WaitReady(5 * time.Second); err != nil {
		t.Fatal(err)
	}
	for name, session := range map[string]*Session{"host": host, "test-viewer": viewer} {
		if session.recoveryTrace == nil {
			t.Fatalf("%s session has no recorder", name)
		}
		if session.recoveryTrace.capacity != 32_768 {
			t.Fatalf("%s diagnostic trace capacity = %d, want 32768",
				name, session.recoveryTrace.capacity)
		}
		if session.apiResources.responderFactory.config.Trace != session.recoveryTrace ||
			session.apiResources.observerFactory.trace != session.recoveryTrace {
			t.Fatalf("%s session split its recovery recorder", name)
		}
		if trace := session.Stats().RecoveryTrace; trace == nil || trace.Source != "pion-host" {
			t.Fatalf("%s trace stats = %#v", name, trace)
		}
	}
	if host.track.trace != host.recoveryTrace {
		t.Fatal("host frame track did not receive the session recorder")
	}
}

func TestSessionSendVideoReportsTrackWriteFailure(t *testing.T) {
	failures := make(chan error, 1)
	session := &Session{
		ready:        true,
		track:        NewFrameTrack("video", "desktop"),
		failedCh:     make(chan struct{}),
		callbackGate: newCallbackGate(),
		callbacks: SessionCallbacks{
			OnError: func(err error) { failures <- err },
		},
	}
	err := session.SendVideo(OutboundFrame{
		StreamID: 1, FrameID: 1, Keyframe: true,
		Dependency: l1t1Dependency(true), Data: testAV1AccessUnit(2_000),
	})
	if err == nil {
		t.Fatal("track write failure unexpectedly succeeded")
	}
	select {
	case reported := <-failures:
		if reported.Error() != err.Error() {
			t.Fatalf("reported error = %q, want %q", reported, err)
		}
	default:
		t.Fatal("track write failure was not reported")
	}
}

func TestSessionDrainImpairmentReportsFailure(t *testing.T) {
	failures := make(chan error, 1)
	controller := newRecoveryImpairmentController(recoveryMatrixProfile{})
	t.Cleanup(func() { _ = controller.Close() })
	controller.mu.Lock()
	controller.asyncError = errors.New("synthetic impairment drain failure")
	controller.mu.Unlock()
	session := &Session{
		ready:        true,
		apiResources: &peerAPIResources{impairment: controller},
		failedCh:     make(chan struct{}),
		callbackGate: newCallbackGate(),
		callbacks: SessionCallbacks{
			OnError: func(err error) { failures <- err },
		},
	}
	err := session.DrainImpairment()
	if err == nil {
		t.Fatal("impairment drain failure unexpectedly succeeded")
	}
	select {
	case reported := <-failures:
		if reported.Error() != err.Error() {
			t.Fatalf("reported error = %q, want %q", reported, err)
		}
	default:
		t.Fatal("impairment drain failure was not reported")
	}
}

func TestSessionRecoveryOffStatsDisableRepair(t *testing.T) {
	session := &Session{
		config: SessionConfiguration{
			ICEPolicy: ICEPolicyStrict,
			Recovery:  RecoveryOff, RTXMaxAge: 125 * time.Millisecond,
		},
		startedAt:    time.Now(),
		apiResources: &peerAPIResources{counters: &RecoveryCounters{}},
		callbackGate: newCallbackGate(),
	}
	stats := session.Stats()
	if stats.NACK || stats.RTX || stats.FEC || stats.FrameAssemblyCapacity != 1 ||
		stats.Recovery.Mode != "off" ||
		stats.Recovery.NACKInspectionIntervalMilliseconds != 0 ||
		stats.Recovery.RTXMaxAgeMilliseconds != 125 ||
		stats.Recovery.RTXPayloadType != nil || stats.Recovery.RTXSSRCNegotiated ||
		len(stats.RTCPFeedback) != 0 ||
		!slices.Equal(stats.HeaderExtensionURIs, []string{
			frameMetadataURI, playoutDelayURI, dependencyDescriptorURI,
		}) {
		t.Fatalf("recovery-off stats = %#v", stats)
	}
}

func TestSessionRejectsWrongChannelKinds(t *testing.T) {
	host, viewer := startSessionPair(t, SessionCallbacks{}, SessionCallbacks{})
	defer host.Close()
	defer viewer.Close()
	if err := host.WaitReady(5 * time.Second); err != nil {
		t.Fatal(err)
	}
	if err := viewer.WaitReady(5 * time.Second); err != nil {
		t.Fatal(err)
	}
	if _, err := viewer.SendInput(testWireMessage(wireKindStop, 16)); err == nil {
		t.Fatal("control kind sent on input channel")
	}
	if err := viewer.SendControl(testWireMessage(wireKindPointer, 29)); err == nil {
		t.Fatal("input kind sent on control channel")
	}
}

func TestSessionReportsRemoteClose(t *testing.T) {
	hostFailure := make(chan error, 1)
	host, viewer := startSessionPair(t, SessionCallbacks{
		OnError: func(err error) { hostFailure <- err },
	}, SessionCallbacks{})
	defer host.Close()
	if err := host.WaitReady(5 * time.Second); err != nil {
		t.Fatal(err)
	}
	if err := viewer.WaitReady(5 * time.Second); err != nil {
		t.Fatal(err)
	}
	if err := viewer.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-hostFailure:
		if err == nil {
			t.Fatal("remote close produced a nil error")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("host did not report the remote close")
	}
}

func TestSessionCloseAfterStopWaitsForRemoteClosure(t *testing.T) {
	controlAtHost := make(chan []byte, 1)
	host, viewer := startSessionPair(t, SessionCallbacks{
		OnMessage: func(channel ChannelKind, data []byte) {
			if channel == ChannelControl {
				controlAtHost <- data
			}
		},
	}, SessionCallbacks{})
	defer host.Close()
	if err := host.WaitReady(5 * time.Second); err != nil {
		t.Fatal(err)
	}
	if err := viewer.WaitReady(5 * time.Second); err != nil {
		t.Fatal(err)
	}

	stop := testWireMessage(wireKindStop, 16)
	if err := viewer.SendControl(stop); err != nil {
		t.Fatal(err)
	}
	requireBytes(t, controlAtHost, stop)
	viewerClosed := make(chan error, 1)
	go func() { viewerClosed <- viewer.Close() }()
	select {
	case err := <-viewerClosed:
		t.Fatalf("viewer close returned before remote closure: %v", err)
	case <-time.After(1500 * time.Millisecond):
	}
	if err := host.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-viewerClosed:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("viewer close did not finish after remote closure")
	}
}

func TestSessionSignalingTimeoutIsBounded(t *testing.T) {
	previous := signalAcceptTimeout
	signalAcceptTimeout = 60 * time.Millisecond
	defer func() { signalAcceptTimeout = previous }()
	port := reserveTCPPort(t)
	started := time.Now()
	_, err := newHostSession(SessionConfiguration{
		ICEPolicy: ICEPolicyStrict,
		LocalIP:   net.ParseIP("127.0.0.1"), SignalPort: port, ICEPort: reserveUDPPort(t),
		Recovery: RecoveryNACKRTX, RTXMaxAge: 30 * time.Millisecond,
	}, SessionCallbacks{})
	if err == nil {
		t.Fatal("host without viewer unexpectedly started")
	}
	if time.Since(started) > time.Second {
		t.Fatalf("signaling timeout took %s", time.Since(started))
	}
}

func TestSessionFlexFECConfigurationFailsClosed(t *testing.T) {
	base := SessionConfiguration{
		ICEPolicy: ICEPolicyStrict,
		LocalIP:   net.ParseIP("127.0.0.1"), SignalPort: 5701, ICEPort: 5700,
		Recovery: RecoveryNACKRTXFlexFEC, RTXMaxAge: 30 * time.Millisecond,
		FlexFECPolicy: FlexFECPolicyAdaptive, ScalabilityMode: AV1ScalabilityL1T3,
		TotalRTPBudgetBitsPerSecond: 8_000_000, FramesPerSecond: 60,
	}
	if err := validateSessionConfiguration(base); err != nil {
		t.Fatalf("valid FlexFEC configuration failed: %v", err)
	}
	if err := validateSessionCallbacks(base, SessionCallbacks{}); err == nil {
		t.Fatal("FlexFEC configuration accepted a missing policy callback")
	}
	if err := validateSessionCallbacks(base, SessionCallbacks{
		OnRecoveryPolicy: func(RecoveryPolicyUpdate) error { return nil },
	}); err != nil {
		t.Fatalf("valid FlexFEC callback failed: %v", err)
	}

	for _, mutate := range []func(*SessionConfiguration){
		func(configuration *SessionConfiguration) { configuration.FlexFECPolicy = 0 },
		func(configuration *SessionConfiguration) { configuration.FlexFECPolicy = 6 },
		func(configuration *SessionConfiguration) { configuration.ScalabilityMode = 0 },
		func(configuration *SessionConfiguration) { configuration.ScalabilityMode = 4 },
		func(configuration *SessionConfiguration) { configuration.TotalRTPBudgetBitsPerSecond = 0 },
		func(configuration *SessionConfiguration) {
			configuration.FlexFECPolicy = FlexFECPolicyLow
			configuration.FlexFECControllerPolicyJSON = []byte(`{"schemaVersion":1}`)
		},
	} {
		configuration := base
		mutate(&configuration)
		if err := validateSessionConfiguration(configuration); err == nil {
			t.Fatalf("invalid FlexFEC configuration passed: %#v", configuration)
		}
	}

	legacy := base
	legacy.Recovery = RecoveryNACKRTX
	legacy.FlexFECPolicy = FlexFECPolicyLow
	if err := validateSessionConfiguration(legacy); err == nil {
		t.Fatal("legacy recovery accepted FlexFEC fields")
	}
}

func TestSessionRTXAgePolicyValidationAndNegotiatedCap(t *testing.T) {
	base := SessionConfiguration{
		ICEPolicy: ICEPolicyStrict,
		LocalIP:   net.ParseIP("127.0.0.1"), SignalPort: 5701, ICEPort: 5700,
		Recovery: RecoveryNACKRTX, RTXMaxAge: 30 * time.Millisecond,
	}
	if err := validateSessionConfiguration(base); err != nil {
		t.Fatalf("legacy fixed configuration failed: %v", err)
	}
	if got := base.negotiatedRTXTime(); got != 30*time.Millisecond {
		t.Fatalf("legacy negotiated RTX time = %s", got)
	}
	rtt := base
	rtt.RTXAgeMode = RTXAgeRTT
	rtt.RTXAgeMultiplierMilli = 1_250
	rtt.RTXAgeCap = 300 * time.Millisecond
	if err := validateSessionConfiguration(rtt); err != nil {
		t.Fatalf("RTT configuration failed: %v", err)
	}
	if got := rtt.negotiatedRTXTime(); got != 300*time.Millisecond {
		t.Fatalf("RTT negotiated RTX time = %s", got)
	}
	for _, mutate := range []func(*SessionConfiguration){
		func(c *SessionConfiguration) { c.RTXAgeMode = 3 },
		func(c *SessionConfiguration) { c.RTXAgeMode = RTXAgeRTT },
		func(c *SessionConfiguration) { c.RTXAgeMode = RTXAgeRTT; c.RTXAgeCap = 300 * time.Millisecond },
		func(c *SessionConfiguration) { c.RTXAgeMode = RTXAgeRTT; c.RTXAgeMultiplierMilli = 1_250 },
		func(c *SessionConfiguration) {
			c.RTXAgeMode = RTXAgeRTT
			c.RTXAgeMultiplierMilli = 1_250
			c.RTXAgeCap = 20 * time.Millisecond
		},
		func(c *SessionConfiguration) { c.RTXAgeMode = RTXAgeFixed; c.RTXAgeMultiplierMilli = 1_250 },
		func(c *SessionConfiguration) { c.RTXAgeMode = RTXAgeFixed; c.RTXAgeCap = 300 * time.Millisecond },
	} {
		candidate := base
		mutate(&candidate)
		if err := validateSessionConfiguration(candidate); err == nil {
			t.Fatalf("invalid RTX age policy passed: %#v", candidate)
		}
	}
}

func TestSessionStaticFlexFECPolicyCallbackFailureKeepsTierOff(t *testing.T) {
	port := reserveUDPPort(t)
	configuration := SessionConfiguration{
		ICEPolicy: ICEPolicyStrict,
		LocalIP:   net.ParseIP("127.0.0.1"), RemoteIP: net.ParseIP("127.0.0.1"),
		SignalPort: port + 1, ICEPort: port,
		Recovery: RecoveryNACKRTXFlexFEC, RTXMaxAge: 30 * time.Millisecond,
		FlexFECPolicy: FlexFECPolicyHigh, ScalabilityMode: AV1ScalabilityL1T3,
		TotalRTPBudgetBitsPerSecond: 8_000_000, FramesPerSecond: 60,
	}
	session, err := createSession(configuration, SessionCallbacks{
		OnRecoveryPolicy: func(RecoveryPolicyUpdate) error { return assertionError("reject") },
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = session.Close() })
	if session.apiResources.flexFECTier.Load() != FlexFECTierOff ||
		session.apiResources.flexFECDegradedReason == "" {
		t.Fatalf("tier=%d degraded=%q", session.apiResources.flexFECTier.Load(), session.apiResources.flexFECDegradedReason)
	}
}

func TestSessionAdaptiveFlexFECControllerStartsOnlyAfterNegotiationAndCloses(t *testing.T) {
	port := reserveUDPPort(t)
	configuration := SessionConfiguration{
		ICEPolicy: ICEPolicyStrict,
		LocalIP:   net.ParseIP("127.0.0.1"), RemoteIP: net.ParseIP("127.0.0.1"),
		SignalPort: port + 1, ICEPort: port,
		Recovery: RecoveryNACKRTXFlexFEC, RTXMaxAge: 30 * time.Millisecond,
		FlexFECPolicy: FlexFECPolicyAdaptive, ScalabilityMode: AV1ScalabilityL1T3,
		TotalRTPBudgetBitsPerSecond: 8_000_000, FramesPerSecond: 60,
	}
	var updates []RecoveryPolicyUpdate
	session, err := createSession(configuration, SessionCallbacks{
		OnRecoveryPolicy: func(update RecoveryPolicyUpdate) error {
			updates = append(updates, update)
			return nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	controller := session.apiResources.flexFECController
	if controller == nil || len(updates) != 1 || updates[0] != (RecoveryPolicyUpdate{
		Sequence: 1, Tier: FlexFECTierOff, MediaBitrateBitsPerSecond: 7_600_000,
	}) {
		t.Fatalf("adaptive controller/updates = %p/%+v", controller, updates)
	}
	controller.mutex.Lock()
	startedBeforeNegotiation := controller.started
	controller.mutex.Unlock()
	if startedBeforeNegotiation {
		t.Fatal("adaptive controller started before negotiation")
	}
	if got := session.apiResources.twccHistory.config.ReorderingGrace; got != 25*time.Millisecond {
		t.Fatalf("TWCC reordering grace = %s, want 25ms", got)
	}
	session.apiResources.SetFlexFECNegotiation(flexFECNegotiation{
		PreferredPayloadType: 45, Primaries: map[int]int{45: 46}, RTXPayloadType: 46, FlexFECPayloadType: 47,
		RepairWindowMicroseconds: 10_000_000, TWCCExtensionID: 5,
		MediaSSRC: 100, RTXSSRC: 101, FlexFECSSRC: 102,
	})
	controller.mutex.Lock()
	startedAfterNegotiation := controller.started
	controller.mutex.Unlock()
	if !startedAfterNegotiation {
		t.Fatal("adaptive controller did not start after negotiation")
	}
	flex, _ := session.apiResources.FlexFECSnapshot()
	frameClock := session.apiResources.recoveryEgressBudget.Snapshot()
	if flex == nil || flex.Controller == nil || flex.Budget == nil ||
		flex.Controller.ControllerVersion != "ll100-d1000-h250-b2x4" ||
		len(flex.Controller.PolicySHA256) != 64 ||
		len(flex.Controller.RetainedTiersSHA256) != 64 ||
		!slices.Equal(flex.Controller.AllowedTiers, []string{"off", "low", "medium", "high"}) ||
		flex.Controller.TransitionSequence != 1 ||
		flex.Controller.AcceptedTransitions != 1 ||
		flex.Controller.RequestedTier != "off" ||
		flex.Budget.ConfiguredRTPBudgetBitsPerSecond != 8_000_000 ||
		flex.Budget.MediaTargetBitsPerSecond != 7_600_000 ||
		frameClock.RateBitsPerSecond != 8_000_000 ||
		frameClock.FramesPerSecond != 60 ||
		frameClock.BurstDurationMilliseconds != 20 {
		t.Fatalf("adaptive FlexFEC stats = %#v", flex)
	}
	if err := session.Close(); err != nil {
		t.Fatal(err)
	}
	if !controller.Snapshot().Closed {
		t.Fatal("adaptive controller remained open after session close")
	}
}

func TestSessionAdaptiveFlexFECRejectsInvalidExplicitPolicy(t *testing.T) {
	port := reserveUDPPort(t)
	configuration := SessionConfiguration{
		ICEPolicy: ICEPolicyStrict,
		LocalIP:   net.ParseIP("127.0.0.1"), RemoteIP: net.ParseIP("127.0.0.1"),
		SignalPort: port + 1, ICEPort: port,
		Recovery: RecoveryNACKRTXFlexFEC, RTXMaxAge: 30 * time.Millisecond,
		FlexFECPolicy: FlexFECPolicyAdaptive, ScalabilityMode: AV1ScalabilityL1T3,
		TotalRTPBudgetBitsPerSecond: 8_000_000, FramesPerSecond: 60,
		FlexFECControllerPolicyJSON: []byte(`{"schemaVersion":1}`),
	}
	if _, err := createSession(configuration, SessionCallbacks{
		OnRecoveryPolicy: func(RecoveryPolicyUpdate) error { return nil },
	}); err == nil {
		t.Fatal("adaptive session accepted invalid explicit controller policy")
	}
}

func TestSessionStatsPublishStrictFlexFECAndTWCCState(t *testing.T) {
	port := reserveUDPPort(t)
	configuration := SessionConfiguration{
		ICEPolicy: ICEPolicyStrict,
		LocalIP:   net.ParseIP("127.0.0.1"), RemoteIP: net.ParseIP("127.0.0.1"),
		SignalPort: port + 1, ICEPort: port,
		Recovery: RecoveryNACKRTXFlexFEC, RTXMaxAge: 30 * time.Millisecond,
		FlexFECPolicy: FlexFECPolicyMedium, ScalabilityMode: AV1ScalabilityL1T3,
		TotalRTPBudgetBitsPerSecond: 8_000_000, FramesPerSecond: 60,
	}
	session, err := createSession(configuration, SessionCallbacks{
		OnRecoveryPolicy: func(RecoveryPolicyUpdate) error { return nil },
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = session.Close() })
	session.apiResources.SetFlexFECNegotiation(flexFECNegotiation{
		PreferredPayloadType: 45, Primaries: map[int]int{45: 46}, RTXPayloadType: 46, FlexFECPayloadType: 47,
		RepairWindowMicroseconds: 10_000_000, TWCCExtensionID: 5,
		MediaSSRC: 100, RTXSSRC: 101, FlexFECSSRC: 102,
	})
	session.apiResources.flexFECCounters.recordSelectedFrame(1)
	session.apiResources.flexFECCounters.recordGroup(5, 1, 200)
	session.apiResources.twccHistory.RecordSent(TWCCSentPacket{
		TransportSequence: 1, Class: TWCCFEC, Bytes: 200, Departure: time.Now(),
	})
	stats := session.Stats()
	if !stats.NACK || !stats.RTX || !stats.FEC || stats.Recovery.Mode != "nack-rtx-flexfec" ||
		!slices.Contains(stats.RTCPFeedback, "transport-cc") || !slices.Contains(stats.HeaderExtensionURIs, twccURI) {
		t.Fatalf("recovery identity = %+v", stats)
	}
	if stats.FlexFEC == nil {
		t.Fatal("missing FlexFEC stats")
	}
	flex := stats.FlexFEC
	if flex.PayloadType != 47 || flex.RepairWindowMicroseconds != 10_000_000 ||
		flex.TWCCExtensionID != 5 || flex.FlexFECSSRC != 102 ||
		flex.Policy != "medium" || flex.CurrentTier != "medium" ||
		flex.ConfiguredRTPBudgetBitsPerSecond != 8_000_000 ||
		flex.MediaBitrateBitsPerSecond != 6_909_090 || flex.FECPackets != 1 ||
		flex.SelectedFramesByTemporalID[1] != 1 || flex.Degraded {
		t.Fatalf("FlexFEC stats = %+v", flex)
	}
	if stats.TWCC == nil || stats.TWCC.ByClass[TWCCFEC].SentBytes != 200 {
		t.Fatalf("TWCC stats = %+v", stats.TWCC)
	}
	if stats.FrameClockBudget == nil ||
		stats.FrameClockBudget.LedgerVersion != recoveryFrameClockBudgetVersion ||
		stats.FrameClockBudget.FramesPerSecond != 60 ||
		stats.FrameClockBudget.BurstCapacityBits != 160_000 {
		t.Fatalf("frame-clock budget = %+v", stats.FrameClockBudget)
	}
	encoded, err := json.Marshal(stats)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(encoded, []byte(`"frameClockBudget"`)) ||
		bytes.Contains(encoded, []byte(`"egressBudget"`)) {
		t.Fatalf("unexpected budget schema: %s", encoded)
	}
}

func TestSessionCallbackGateExcludesCallbacksAfterClose(t *testing.T) {
	for iteration := 0; iteration < 1_000; iteration++ {
		gate := newCallbackGate()
		started := make(chan struct{})
		release := make(chan struct{})
		callbackDone := make(chan struct{})
		go func() {
			if !gate.begin() {
				close(callbackDone)
				return
			}
			close(started)
			<-release
			gate.end()
			close(callbackDone)
		}()
		<-started
		closeDone := make(chan struct{})
		go func() {
			gate.closeAndWait()
			close(closeDone)
		}()
		select {
		case <-closeDone:
			t.Fatal("close returned while callback was active")
		default:
		}
		close(release)
		<-callbackDone
		<-closeDone
		if gate.begin() {
			t.Fatal("callback acquired after close")
		}
	}
}

func TestSessionRecoveryKeyframesAreGatedAndReported(t *testing.T) {
	hostEvents := make(chan uint64, 2)
	viewerEvents := make(chan uint64, 2)
	host, viewer := startSessionPair(t, SessionCallbacks{
		OnRecoveryKeyframe: func(streamID uint64) { hostEvents <- streamID },
	}, SessionCallbacks{
		OnRecoveryKeyframe: func(streamID uint64) { viewerEvents <- streamID },
	})
	defer host.Close()
	defer viewer.Close()
	if err := host.WaitReady(5 * time.Second); err != nil {
		t.Fatal(err)
	}
	if err := viewer.WaitReady(5 * time.Second); err != nil {
		t.Fatal(err)
	}

	// An SSRC this session carries no video track for, so it resolves to the eager stream id --
	// the same 0 the interceptor-level request always produced.
	host.apiResources.requestRecoveryKeyframe(12_345)
	viewer.emitRecoveryKeyframe(91)
	requireRecoveryStream(t, hostEvents, 0)
	requireRecoveryStream(t, viewerEvents, 91)

	hostStats := host.Stats()
	viewerStats := viewer.Stats()
	if hostStats.Recovery.RecoveryKeyframeRequests != 1 ||
		viewerStats.Recovery.RecoveryKeyframeRequests != 1 ||
		hostStats.Recovery.RecoveryKeyframeRequests+
			viewerStats.Recovery.RecoveryKeyframeRequests != 2 {
		t.Fatalf("recovery stats = host %#v, viewer %#v", hostStats.Recovery, viewerStats.Recovery)
	}
	if hostStats.Recovery.Mode != "nack-rtx" ||
		hostStats.Recovery.NACKInspectionIntervalMilliseconds != 2 ||
		hostStats.Recovery.RTXMaxAgeMilliseconds != 30 ||
		hostStats.Recovery.PrimaryPayloadType != 45 ||
		hostStats.Recovery.RTXPayloadType == nil || *hostStats.Recovery.RTXPayloadType != 46 ||
		!hostStats.NACK || !hostStats.RTX || hostStats.FEC {
		t.Fatalf("host recovery configuration stats = %#v", hostStats)
	}

	if err := viewer.Close(); err != nil {
		t.Fatal(err)
	}
	viewer.emitRecoveryKeyframe(92)
	select {
	case streamID := <-viewerEvents:
		t.Fatalf("post-close recovery callback delivered stream %d", streamID)
	case <-time.After(10 * time.Millisecond):
	}
	if got := viewer.Stats().Recovery.RecoveryKeyframeRequests; got != 1 {
		t.Fatalf("post-close recovery request count = %d, want 1", got)
	}
}

func TestSessionTreatsRemoteClosureAsExpectedAfterStop(t *testing.T) {
	session := &Session{}
	if session.remoteClosureExpected() {
		t.Fatal("fresh session unexpectedly accepts remote closure")
	}
	session.markRemoteStopReceived()
	if !session.remoteClosureExpected() {
		t.Fatal("valid remote stop did not make subsequent closure expected")
	}
}

func TestSessionDropsInputAfterRemoteStop(t *testing.T) {
	session := &Session{remoteStopReceived: true}
	disposition, err := session.SendInput(testWireMessage(wireKindInputAcknowledgment, 16))
	if err != nil {
		t.Fatalf("input after remote stop returned an error: %v", err)
	}
	if disposition != SendDispositionDropped {
		t.Fatalf("input after remote stop disposition = %v, want dropped", disposition)
	}
}

func startSessionPair(
	t *testing.T,
	hostCallbacks SessionCallbacks,
	viewerCallbacks SessionCallbacks,
) (*Session, *Session) {
	return startSessionPairWithFrameCallback(t, hostCallbacks, viewerCallbacks, nil)
}

func startSessionPairWithFrameCallback(
	t *testing.T,
	hostCallbacks SessionCallbacks,
	viewerCallbacks SessionCallbacks,
	onFrame func(AssembledFrame),
) (*Session, *Session) {
	return startSessionPairConfiguredWithFrame(
		t, hostCallbacks, viewerCallbacks, false, onFrame,
	)
}

func startSessionPairConfigured(
	t *testing.T,
	hostCallbacks SessionCallbacks,
	viewerCallbacks SessionCallbacks,
	diagnosticRecoveryTrace bool,
) (*Session, *Session) {
	return startSessionPairConfiguredWithFrame(
		t, hostCallbacks, viewerCallbacks, diagnosticRecoveryTrace, nil,
	)
}

func startSessionPairConfiguredWithFrame(
	t *testing.T,
	hostCallbacks SessionCallbacks,
	viewerCallbacks SessionCallbacks,
	diagnosticRecoveryTrace bool,
	onFrame func(AssembledFrame),
) (*Session, *Session) {
	t.Helper()
	signalPort := reserveTCPPort(t)
	icePort := reserveUDPPort(t)
	if signalPort == icePort {
		return startSessionPairConfiguredWithFrame(
			t, hostCallbacks, viewerCallbacks, diagnosticRecoveryTrace, onFrame,
		)
	}
	viewerICEPort := reserveUDPPort(t)
	for viewerICEPort == icePort || viewerICEPort == signalPort {
		viewerICEPort = reserveUDPPort(t)
	}
	type hostResult struct {
		session *Session
		err     error
	}
	hostResultChannel := make(chan hostResult, 1)
	go func() {
		session, err := newHostSession(SessionConfiguration{
			ICEPolicy: ICEPolicyStrict,
			LocalIP:   net.ParseIP("127.0.0.1"), SignalPort: signalPort, ICEPort: icePort,
			Recovery: RecoveryNACKRTX, RTXMaxAge: 30 * time.Millisecond,
			DiagnosticRecoveryTrace: diagnosticRecoveryTrace,
		}, hostCallbacks)
		hostResultChannel <- hostResult{session, err}
	}()
	viewer, err := newTestViewerSession(SessionConfiguration{
		ICEPolicy: ICEPolicyStrict,
		LocalIP:   net.ParseIP("127.0.0.1"), RemoteIP: net.ParseIP("127.0.0.1"),
		SignalPort: signalPort, ICEPort: viewerICEPort,
		Recovery: RecoveryNACKRTX, RTXMaxAge: 30 * time.Millisecond,
		DiagnosticRecoveryTrace: diagnosticRecoveryTrace,
	}, viewerCallbacks, onFrame)
	if err != nil {
		t.Fatal(err)
	}
	hostOutcome := <-hostResultChannel
	if hostOutcome.err != nil {
		viewer.Close()
		t.Fatal(hostOutcome.err)
	}
	return hostOutcome.session, viewer
}

func requireBytes(t *testing.T, channel <-chan []byte, wanted []byte) {
	t.Helper()
	select {
	case received := <-channel:
		if !bytes.Equal(received, wanted) {
			t.Fatalf("received %x, want %x", received, wanted)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for DataChannel message")
	}
}

func requireRecoveryStream(t *testing.T, channel <-chan uint64, wanted uint64) {
	t.Helper()
	select {
	case streamID := <-channel:
		if streamID != wanted {
			t.Fatalf("recovery stream = %d, want %d", streamID, wanted)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("timed out waiting for recovery stream %d", wanted)
	}
}

// ─── readiness under each ICE policy ────────────────────────────────────────────────────────────
//
// The policy decision is a PURE PREDICATE so it can be tested exhaustively: fabricating a real
// peer-reflexive candidate pair in a unit test would need a live connection, and the thing worth
// testing is the rule, not pion's plumbing.

func TestStrictReadinessRequiresTheConfiguredHostPair(t *testing.T) {
	facts := selectedPairFacts{
		localProtocolUDP: true, remoteProtocolUDP: true,
		localHost: true, remoteHost: true,
		localAddress: "127.0.0.1", remoteAddress: "127.0.0.1",
		wantLocalAddress: "127.0.0.1", wantRemoteAddress: "127.0.0.1",
	}
	if err := selectedPairUsable(ICEPolicyStrict, facts); err != nil {
		t.Fatalf("strict must accept the exact configured host pair: %v", err)
	}
	prflx := facts
	prflx.remoteHost = false
	if err := selectedPairUsable(ICEPolicyStrict, prflx); err == nil {
		t.Fatal("strict must reject a peer-reflexive remote: it asserts the direct path it configured")
	}
	moved := facts
	moved.remoteAddress = "192.168.1.9"
	if err := selectedPairUsable(ICEPolicyStrict, moved); err == nil {
		t.Fatal("strict must reject a pair whose remote is not the configured address")
	}
}

// Under lan the pair's type and addresses are UNKNOWABLE in advance, so requiring them is a
// precondition that can never be met — which is why readiness never arrived for a browser.
func TestLANReadinessAcceptsAPeerReflexivePair(t *testing.T) {
	facts := selectedPairFacts{
		localProtocolUDP: true, remoteProtocolUDP: true,
		localHost: true, remoteHost: false,
		localAddress: "192.168.14.27", remoteAddress: "192.168.14.51",
	}
	if err := selectedPairUsable(ICEPolicyLAN, facts); err != nil {
		t.Fatalf("lan must accept a usable prflx pair: %v", err)
	}
}

// What lan still refuses. A usable pair is the one thing it does assert.
func TestLANReadinessStillRequiresUDP(t *testing.T) {
	facts := selectedPairFacts{
		localProtocolUDP: false, remoteProtocolUDP: true,
		localHost: true, remoteHost: true,
	}
	if err := selectedPairUsable(ICEPolicyLAN, facts); err == nil {
		t.Fatal("lan must still require UDP on both sides")
	}
}

// THE sync.Once IS THE POINT OF THIS ONE. `fail` wraps its body in a sync.Once and OnError is the
// C ABI's only error observable, so a precondition that fires on EVERY same-machine session spends
// the one shot before anything real can use it. An unmet precondition is "not ready yet", and
// readiness can arrive later as candidate pairs change, so treating it as terminal is wrong
// independently of the once.
func TestAnUnusableCandidatePairBlocksReadinessWithoutFailingTheSession(t *testing.T) {
	session := newTestOfferSession(t, SessionCallbacks{
		OnLocalICECandidate: func(string) {},
		OnError:             func(error) {},
	})

	// DRIVE THE REAL PATH. An earlier version of this test set candidateObstacle by hand and called
	// readinessBlockersLocked, which could not see the session being failed at all — a test named for
	// a behaviour it did not exercise, and a mutation putting session.fail back passed it. Clearing
	// every OTHER blocker is what makes maybeReady reach the candidate check; the test session has no
	// connection, so selectedCandidateLocked fails on the missing ICE transport, which is the shape
	// this fix is about.
	session.mutex.Lock()
	session.signalingComplete, session.mediaReady, session.peerConnected = true, true, true
	session.inputOpen, session.controlOpen = true, true
	session.mutex.Unlock()

	session.maybeReady()

	session.mutex.Lock()
	failure, obstacle, ready := session.failure, session.candidateObstacle, session.ready
	blockers := session.readinessBlockersLocked()
	session.mutex.Unlock()

	if failure != nil {
		t.Fatalf("an unusable pair must not fail the session; that burns the one error shot: %v", failure)
	}
	if ready {
		t.Fatal("it must not reach ready either — the precondition was not met")
	}
	if obstacle == nil {
		t.Fatal("the obstacle must be recorded, or WaitReady cannot name what it is waiting on")
	}
	found := false
	for _, blocker := range blockers {
		if strings.Contains(blocker, "candidate") {
			found = true
		}
	}
	if !found {
		t.Fatalf("it must be REPORTED as a blocker so WaitReady can name it, got %v", blockers)
	}
}
