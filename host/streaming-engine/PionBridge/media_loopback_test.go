package main

import (
	"bytes"
	"net"
	"testing"
	"time"

	"github.com/pion/webrtc/v4"
)

func TestMediaLoopbackSendsNormalizedFramesThroughDTLSSRTP(t *testing.T) {
	port := reserveUDPPort(t)
	hostAPI, hostResources, err := newPeerAPI(PeerConfig{
		ICEPolicy: ICEPolicyStrict,
		LocalIP:   net.ParseIP("127.0.0.1"),
		RemoteIP:  net.ParseIP("127.0.0.1"), ICEPort: port, SignalPort: port + 1,
		Recovery: RecoveryNACKRTX, RTXMaxAge: 30 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer hostResources.Close()
	viewerPort := reserveUDPPort(t)
	for viewerPort == port || viewerPort == port+1 {
		viewerPort = reserveUDPPort(t)
	}
	viewerAPI, viewerResources, err := newTestViewerAPI(PeerConfig{
		ICEPolicy: ICEPolicyStrict,
		LocalIP:   net.ParseIP("127.0.0.1"),
		RemoteIP:  net.ParseIP("127.0.0.1"), ICEPort: viewerPort, SignalPort: port + 1,
		Recovery: RecoveryNACKRTX, RTXMaxAge: 30 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer viewerResources.Close()

	host, err := hostAPI.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	defer host.Close()
	viewer, err := viewerAPI.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	defer viewer.Close()

	track := NewFrameTrack("video", "desktop")
	if _, err := host.AddTrack(track); err != nil {
		t.Fatal(err)
	}
	if _, err := viewer.AddTransceiverFromKind(
		webrtc.RTPCodecTypeVideo,
		webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionRecvonly},
	); err != nil {
		t.Fatal(err)
	}

	received := make(chan AssembledFrame, 2)
	receiveErrors := make(chan error, 1)
	senderReportRead := make(chan error, 1)
	viewer.OnTrack(func(remote *webrtc.TrackRemote, receiver *webrtc.RTPReceiver) {
		go func() {
			_, _, err := receiver.ReadRTCP()
			senderReportRead <- err
		}()
		go func() {
			receiveErrors <- readTestAV1Track(
				remote,
				receiver,
				30*time.Millisecond,
				viewerResources.counters,
				func(frame AssembledFrame) { received <- frame },
				func(uint64) {},
			)
		}()
	})

	offer := gatherDescription(t, viewer, true)
	offer, err = advertiseRTXTime(offer, 30*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	hostOffer, err := preparePionRemoteDescription(offer, 30*time.Millisecond, false)
	if err != nil {
		t.Fatal(err)
	}
	if err := host.SetRemoteDescription(hostOffer); err != nil {
		t.Fatal(err)
	}
	answer := gatherDescription(t, host, false)
	answer, err = advertiseRTXTime(answer, 30*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	viewerAnswer, err := preparePionRemoteDescription(answer, 30*time.Millisecond, true)
	if err != nil {
		t.Fatal(err)
	}
	if err := viewer.SetRemoteDescription(viewerAnswer); err != nil {
		t.Fatal(err)
	}
	waitForPeerState(t, host, webrtc.PeerConnectionStateConnected)
	waitForPeerState(t, viewer, webrtc.PeerConnectionStateConnected)

	frames := []OutboundFrame{
		{
			StreamID: 91, FrameID: 1, InputSequence: 101,
			HostProcessingNanos: 1_200, EncodeNanos: 900,
			Keyframe: true, Dependency: l1t1Dependency(true), Data: testAV1AccessUnit(3_000),
		},
		{
			StreamID: 91, FrameID: 2, InputSequence: 102,
			HostProcessingNanos: 1_300, EncodeNanos: 950,
			Dependency: l1t1Dependency(false), Data: testAV1AccessUnit(400),
		},
	}
	for _, outbound := range frames {
		started := time.Now()
		if err := track.WriteAccessUnit(outbound); err != nil {
			t.Fatal(err)
		}
		select {
		case inbound := <-received:
			if time.Since(started) > 500*time.Millisecond {
				t.Fatalf("completed frame was held for %s", time.Since(started))
			}
			if inbound.Metadata.StreamID != outbound.StreamID ||
				inbound.Metadata.FrameID != outbound.FrameID ||
				inbound.Metadata.InputSequence != outbound.InputSequence ||
				inbound.Metadata.HostProcessingNanos != outbound.HostProcessingNanos ||
				inbound.Metadata.EncodeNanos != outbound.EncodeNanos ||
				inbound.Metadata.Keyframe != outbound.Keyframe {
				t.Fatalf("received metadata = %#v, outbound = %#v", inbound.Metadata, outbound)
			}
			if !bytes.Equal(inbound.Data, outbound.Data[2:]) {
				t.Fatalf("normalized frame %d differs", outbound.FrameID)
			}
		case err := <-receiveErrors:
			t.Fatalf("receiver failed: %v", err)
		case <-time.After(2 * time.Second):
			t.Fatal("timed out waiting for encrypted media frame")
		}
	}
	deadline := time.Now().Add(1_500 * time.Millisecond)
	for time.Now().Before(deadline) &&
		viewerResources.counters.Snapshot().SenderReportsReceived == 0 {
		time.Sleep(5 * time.Millisecond)
	}
	if got := viewerResources.counters.Snapshot().SenderReportsReceived; got == 0 {
		t.Fatal("viewer received no RTCP sender report for the active media SSRC")
	}
	select {
	case err := <-senderReportRead:
		if err != nil {
			t.Fatalf("read sender report: %v", err)
		}
	default:
		t.Fatal("sender-report read did not complete")
	}
}

func gatherDescription(t *testing.T, peer *webrtc.PeerConnection, offer bool) webrtc.SessionDescription {
	t.Helper()
	var description webrtc.SessionDescription
	var err error
	if offer {
		description, err = peer.CreateOffer(nil)
	} else {
		description, err = peer.CreateAnswer(nil)
	}
	if err != nil {
		t.Fatal(err)
	}
	complete := webrtc.GatheringCompletePromise(peer)
	if err := peer.SetLocalDescription(description); err != nil {
		t.Fatal(err)
	}
	select {
	case <-complete:
	case <-time.After(5 * time.Second):
		t.Fatal("ICE gathering timed out")
	}
	return *peer.LocalDescription()
}

func waitForPeerState(t *testing.T, peer *webrtc.PeerConnection, wanted webrtc.PeerConnectionState) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if peer.ConnectionState() == wanted {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("peer state = %s, want %s", peer.ConnectionState(), wanted)
}
