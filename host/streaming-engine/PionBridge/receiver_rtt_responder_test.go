package main

import (
	"sync"
	"testing"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/rtcp"
	"github.com/pion/rtp"
	"github.com/pion/transport/v4/packetio"
)

func TestReceiverRTTResponderObservesMediaRTTForBoundSenderSSRC(t *testing.T) {
	now := time.Unix(1_780_000_000, 500_000_000)
	estimator := &mediaRTTEstimator{}
	responder := &receiverRTTResponder{config: ReceiverRTTResponderConfig{
		Now:      func() time.Time { return now },
		MediaRTT: estimator,
	}}
	responder.BindLocalStream(
		&interceptor.StreamInfo{SSRC: 0x11223344},
		interceptor.RTPWriterFunc(func(*rtp.Header, []byte, interceptor.Attributes) (int, error) {
			return 0, nil
		}),
	)

	arrival := compactNTP(now)
	responder.observeMediaRTT([]rtcp.Packet{&rtcp.ReceiverReport{
		SSRC: 0x55667788,
		Reports: []rtcp.ReceptionReport{
			{SSRC: 0x99999999, LastSenderReport: arrival - 10_000, Delay: 1_000},
			{SSRC: 0x11223344, LastSenderReport: arrival - 4_000, Delay: 1_000},
		},
	}}, now)

	got, observations, ok := estimator.Snapshot()
	want := compactNTPTicksToDuration(3_000)
	if !ok || got != want || observations != 1 {
		t.Fatalf("media RTT = (%v, %d, %t), want (%v, 1, true)", got, observations, ok, want)
	}
}

func TestReceiverRTTResponderRejectsInvalidMediaRTTSamplesAndHandlesWrap(t *testing.T) {
	estimator := &mediaRTTEstimator{}
	now := time.Unix(1_780_000_000, 0)
	arrival := compactNTP(now)
	responder := &receiverRTTResponder{
		config:     ReceiverRTTResponderConfig{Now: func() time.Time { return now }, MediaRTT: estimator},
		senderSSRC: 7,
	}

	responder.observeMediaRTT([]rtcp.Packet{&rtcp.ReceiverReport{Reports: []rtcp.ReceptionReport{
		{SSRC: 7, LastSenderReport: 0, Delay: 1},
		{SSRC: 7, LastSenderReport: arrival - uint32(11*65_536), Delay: 0},
	}}}, now)
	if _, observations, ok := estimator.Snapshot(); ok || observations != 0 {
		t.Fatalf("invalid media RTT was retained: observations=%d ok=%t", observations, ok)
	}

	wrapArrival := uint32(500)
	responder.observeMediaRTTAtCompactNTP([]rtcp.Packet{&rtcp.ReceiverReport{
		Reports: []rtcp.ReceptionReport{{
			SSRC: 7, LastSenderReport: ^uint32(0) - 999, Delay: 500,
		}},
	}}, wrapArrival)
	got, observations, ok := estimator.Snapshot()
	if !ok || got != compactNTPTicksToDuration(1_000) || observations != 1 {
		t.Fatalf("wrapped media RTT = (%v, %d, %t)", got, observations, ok)
	}
}

func TestMediaRTTEstimatorSupportsConcurrentSnapshots(t *testing.T) {
	estimator := &mediaRTTEstimator{}
	var workers sync.WaitGroup
	for index := range 8 {
		workers.Add(1)
		go func(offset int) {
			defer workers.Done()
			for sample := range 1_000 {
				estimator.Observe(time.Duration(offset+sample+1) * time.Microsecond)
				_, _, _ = estimator.Snapshot()
			}
		}(index)
	}
	workers.Wait()
	latest, observations, ok := estimator.Snapshot()
	if !ok || latest <= 0 || observations != 8_000 {
		t.Fatalf("concurrent estimator = (%v, %d, %t)", latest, observations, ok)
	}
}

func TestReceiverRTTResponderAnswersRRTRBeforeSSRCStreamDemux(t *testing.T) {
	receivedAt := time.Unix(100, 0)
	nowCalls := 0
	counters := &RecoveryCounters{}
	factory := NewReceiverRTTResponder(ReceiverRTTResponderConfig{
		Counters: counters,
		Now: func() time.Time {
			nowCalls++
			if nowCalls == 1 {
				return receivedAt
			}
			return receivedAt.Add(250 * time.Millisecond)
		},
	})
	bound, err := factory.NewInterceptor("receiver-rtt")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = bound.Close() })

	bound.BindLocalStream(&interceptor.StreamInfo{SSRC: 0x11223344}, interceptor.RTPWriterFunc(
		func(*rtp.Header, []byte, interceptor.Attributes) (int, error) { return 0, nil },
	))
	responses := make(chan []rtcp.Packet, 2)
	bound.BindRTCPWriter(interceptor.RTCPWriterFunc(func(
		packets []rtcp.Packet,
		_ interceptor.Attributes,
	) (int, error) {
		responses <- append([]rtcp.Packet(nil), packets...)
		return len(packets), nil
	}))

	const receiverSSRC = 0x55667788
	receiverNTP := uint64(0x0102030405060708)
	incoming, err := (&rtcp.ExtendedReport{
		SenderSSRC: receiverSSRC,
		Reports: []rtcp.ReportBlock{
			&rtcp.ReceiverReferenceTimeReportBlock{NTPTimestamp: receiverNTP},
		},
	}).Marshal()
	if err != nil {
		t.Fatal(err)
	}
	buffer := factory.NewPacketBuffer(packetio.RTCPBufferPacket, receiverSSRC)
	t.Cleanup(func() { _ = buffer.Close() })
	if count, err := buffer.Write(incoming); err != nil || count != len(incoming) {
		t.Fatalf("buffer write = (%d, %v), want (%d, nil)", count, err, len(incoming))
	}
	mediaBuffer := factory.NewPacketBuffer(packetio.RTCPBufferPacket, 0x11223344)
	t.Cleanup(func() { _ = mediaBuffer.Close() })
	if count, err := mediaBuffer.Write(incoming); err != nil || count != len(incoming) {
		t.Fatalf("duplicate buffer write = (%d, %v), want (%d, nil)", count, err, len(incoming))
	}

	select {
	case packets := <-responses:
		if len(packets) != 1 {
			t.Fatalf("response packet count = %d, want 1", len(packets))
		}
		xr, ok := packets[0].(*rtcp.ExtendedReport)
		if !ok || xr.SenderSSRC != 0x11223344 || len(xr.Reports) != 1 {
			t.Fatalf("response XR = %#v", packets[0])
		}
		dlrr, ok := xr.Reports[0].(*rtcp.DLRRReportBlock)
		if !ok || len(dlrr.Reports) != 1 {
			t.Fatalf("response DLRR = %#v", xr.Reports[0])
		}
		want := rtcp.DLRRReport{
			SSRC:   receiverSSRC,
			LastRR: uint32(receiverNTP >> 16),
			DLRR:   16_384,
		}
		if dlrr.Reports[0] != want {
			t.Fatalf("response DLRR = %#v, want %#v", dlrr.Reports[0], want)
		}
	case <-time.After(time.Second):
		t.Fatal("RRTR buffered before SSRC demux did not produce a DLRR response")
	}
	select {
	case packets := <-responses:
		t.Fatalf("duplicate SSRC-buffer delivery produced a second DLRR: %#v", packets)
	case <-time.After(10 * time.Millisecond):
	}
	got := counters.Snapshot()
	if got.RTCPPacketsObserved != 2 || got.RRTRPacketsReceived != 1 || got.DLRRPacketsSent != 1 {
		t.Fatalf("receiver RTT counters = %#v, want observed=2 rrtr=1 dlrr=1", got)
	}
}
