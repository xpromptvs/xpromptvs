package main

import (
	"reflect"
	"testing"

	"github.com/pion/interceptor"
	"github.com/pion/rtcp"
	"github.com/pion/rtp"
)

func TestRecoveryTraceHooksObserverBuffersNACKBeforeWrappedWrite(t *testing.T) {
	recorder := newIncrementingRecoveryTraceRecorder(16)
	factory := NewRecoveryObserver(&RecoveryCounters{}, nil, recorder)
	observer, err := factory.NewInterceptor("traced-observer")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = observer.Close() })

	called := false
	writer := observer.BindRTCPWriter(interceptor.RTCPWriterFunc(func(
		_ []rtcp.Packet,
		_ interceptor.Attributes,
	) (int, error) {
		called = true
		if got := recoveryTraceKinds(recorder); !reflect.DeepEqual(got, []recoveryTraceKind{traceNACKBuffered}) {
			t.Fatalf("trace at wrapped writer = %v", got)
		}
		return 1, nil
	}))
	if _, err := writer.Write([]rtcp.Packet{&rtcp.TransportLayerNack{
		MediaSSRC: 10,
		Nacks:     rtcp.NackPairsFromSequenceNumbers([]uint16{77}),
	}}, nil); err != nil {
		t.Fatal(err)
	}
	if !called {
		t.Fatal("wrapped RTCP writer was not called")
	}
	event := recoveryTraceEvents(recorder)[0]
	if event.MediaSSRC == nil || *event.MediaSSRC != 10 ||
		event.RTPSequence == nil || *event.RTPSequence != 77 {
		t.Fatalf("buffered NACK event = %#v", event)
	}
}

func TestRecoveryTraceHooksObserverRecordsRequestedRTXArrival(t *testing.T) {
	recorder := newIncrementingRecoveryTraceRecorder(16)
	factory := NewRecoveryObserver(&RecoveryCounters{}, nil, recorder)
	observer, err := factory.NewInterceptor("traced-rtx-observer")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = observer.Close() })

	writer := observer.BindRTCPWriter(interceptor.RTCPWriterFunc(func(
		packets []rtcp.Packet,
		_ interceptor.Attributes,
	) (int, error) {
		return len(packets), nil
	}))
	if _, err := writer.Write([]rtcp.Packet{&rtcp.TransportLayerNack{
		MediaSSRC: 10,
		Nacks:     rtcp.NackPairsFromSequenceNumbers([]uint16{77}),
	}}, nil); err != nil {
		t.Fatal(err)
	}
	raw := marshalObserverRTX(t, 77, 100)
	reader := observer.BindRemoteStream(
		&interceptor.StreamInfo{SSRC: 20, PayloadType: 46, MimeType: "video/rtx"},
		interceptor.RTPReaderFunc(func(
			buffer []byte,
			attributes interceptor.Attributes,
		) (int, interceptor.Attributes, error) {
			copy(buffer, raw)
			return len(raw), attributes, nil
		}),
	)
	if _, _, err := reader.Read(make([]byte, 1_500), nil); err != nil {
		t.Fatal(err)
	}

	want := []recoveryTraceKind{traceNACKBuffered, traceRTXArrived}
	if got := recoveryTraceKinds(recorder); !reflect.DeepEqual(got, want) {
		t.Fatalf("receiver recovery trace = %v, want %v", got, want)
	}
}

func TestRecoveryObserverCountsIncomingSenderReports(t *testing.T) {
	counters := &RecoveryCounters{}
	factory := NewRecoveryObserver(counters, nil)
	observer, err := factory.NewInterceptor("sender-report-observer")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = observer.Close() })
	raw, err := rtcp.Marshal([]rtcp.Packet{&rtcp.SenderReport{
		SSRC: 0x11223344, NTPTime: 0x0102030405060708,
		RTPTime: 90_000, PacketCount: 10, OctetCount: 1_000,
	}})
	if err != nil {
		t.Fatal(err)
	}
	reader := observer.BindRTCPReader(interceptor.RTCPReaderFunc(func(
		buffer []byte,
		attributes interceptor.Attributes,
	) (int, interceptor.Attributes, error) {
		copy(buffer, raw)
		return len(raw), attributes, nil
	}))
	if _, _, err := reader.Read(make([]byte, 1_500), nil); err != nil {
		t.Fatal(err)
	}
	if got := counters.Snapshot().SenderReportsReceived; got != 1 {
		t.Fatalf("sender reports received = %d, want 1", got)
	}
}

func TestRecoveryObserverImpairmentKeepsNACKAndDropsTWCCIndependently(t *testing.T) {
	controller := newRecoveryImpairmentController(recoveryMatrixProfile{
		TWCCLossBasisPoints: 10_000,
	})
	t.Cleanup(func() { _ = controller.Close() })
	if err := controller.Activate(); err != nil {
		t.Fatal(err)
	}
	factory := NewRecoveryObserver(&RecoveryCounters{}, nil).WithImpairment(controller)
	observer, err := factory.NewInterceptor("compound-twcc-impairment")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = observer.Close() })
	raw, err := rtcp.Marshal([]rtcp.Packet{
		&rtcp.ReceiverReport{SSRC: 0x11223344},
		&rtcp.TransportLayerCC{
			Header: rtcp.Header{
				Padding: true,
				Count:   rtcp.FormatTCC,
				Type:    rtcp.TypeTransportSpecificFeedback,
				Length:  5,
			},
			SenderSSRC:         0x11223344,
			MediaSSRC:          0x55667788,
			BaseSequenceNumber: 10,
			PacketStatusCount:  1,
			ReferenceTime:      10,
			PacketChunks: []rtcp.PacketStatusChunk{&rtcp.RunLengthChunk{
				Type:               rtcp.TypeTCCRunLengthChunk,
				PacketStatusSymbol: rtcp.TypeTCCPacketReceivedSmallDelta,
				RunLength:          1,
			}},
			RecvDeltas: []*rtcp.RecvDelta{{
				Type: rtcp.TypeTCCPacketReceivedSmallDelta, Delta: 250,
			}},
		},
		&rtcp.TransportLayerNack{
			SenderSSRC: 0x11223344,
			MediaSSRC:  0x55667788,
			Nacks:      rtcp.NackPairsFromSequenceNumbers([]uint16{77}),
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if got := controller.classifyDatagram(matrixViewer, raw).Class; got != matrixPacketOther {
		t.Fatalf("encrypted RTCP envelope class = %q, want %q", got, matrixPacketOther)
	}
	reader := observer.BindRTCPReader(interceptor.RTCPReaderFunc(func(
		buffer []byte,
		attributes interceptor.Attributes,
	) (int, interceptor.Attributes, error) {
		copy(buffer, raw)
		return len(raw), attributes, nil
	}))
	buffer := make([]byte, 1_500)
	count, _, err := reader.Read(buffer, nil)
	if err != nil {
		t.Fatal(err)
	}
	packets, err := rtcp.Unmarshal(buffer[:count])
	if err != nil {
		t.Fatalf("unmarshal filtered RTCP %x (%d bytes): %v", buffer[:count], count, err)
	}
	if len(packets) != 2 {
		t.Fatalf("forwarded RTCP packets = %#v, want RR and NACK", packets)
	}
	if _, ok := packets[0].(*rtcp.ReceiverReport); !ok {
		t.Fatalf("first forwarded RTCP packet = %T, want Receiver Report", packets[0])
	}
	if _, ok := packets[1].(*rtcp.TransportLayerNack); !ok {
		t.Fatalf("second forwarded RTCP packet = %T, want NACK", packets[1])
	}
	snapshot := controller.Snapshot()
	if snapshot.ControllerDropped[matrixPacketTWCC].Packets != 1 ||
		snapshot.Delivered[matrixPacketNACK].Packets != 1 {
		t.Fatalf("independent decrypted RTCP accounting = %#v", snapshot)
	}
}

func TestRecoveryObserverDropsEncryptedCompoundNACKAfterDecryption(t *testing.T) {
	controller := newRecoveryImpairmentController(recoveryMatrixProfile{
		NACKLossBasisPoints: 10_000,
	})
	t.Cleanup(func() { _ = controller.Close() })
	if err := controller.Activate(); err != nil {
		t.Fatal(err)
	}
	factory := NewRecoveryObserver(&RecoveryCounters{}, nil).WithImpairment(controller)
	observer, err := factory.NewInterceptor("compound-nack-impairment")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = observer.Close() })
	raw, err := rtcp.Marshal([]rtcp.Packet{
		&rtcp.ReceiverReport{SSRC: 0x11223344},
		&rtcp.TransportLayerNack{
			SenderSSRC: 0x11223344,
			MediaSSRC:  0x55667788,
			Nacks:      rtcp.NackPairsFromSequenceNumbers([]uint16{77}),
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	reader := observer.BindRTCPReader(interceptor.RTCPReaderFunc(func(
		buffer []byte,
		attributes interceptor.Attributes,
	) (int, interceptor.Attributes, error) {
		copy(buffer, raw)
		return len(raw), attributes, nil
	}))
	buffer := make([]byte, 1_500)
	count, _, err := reader.Read(buffer, nil)
	if err != nil {
		t.Fatal(err)
	}
	packets, err := rtcp.Unmarshal(buffer[:count])
	if err != nil {
		t.Fatal(err)
	}
	if len(packets) != 1 {
		t.Fatalf("forwarded RTCP packets = %#v, want only Receiver Report", packets)
	}
	if _, ok := packets[0].(*rtcp.ReceiverReport); !ok {
		t.Fatalf("forwarded RTCP packet = %T, want Receiver Report", packets[0])
	}
	snapshot := controller.Snapshot()
	if snapshot.Attempted[matrixPacketNACK].Packets != 1 ||
		snapshot.ControllerDropped[matrixPacketNACK].Packets != 1 ||
		snapshot.Delivered[matrixPacketNACK].Packets != 0 {
		t.Fatalf("decrypted NACK accounting = %#v", snapshot)
	}
}

func TestRecoveryObserverCountsNACKAndUniqueRTXRepair(t *testing.T) {
	counters := &RecoveryCounters{}
	negotiated := 0
	factory := NewRecoveryObserver(counters, func() { negotiated++ })
	observer, err := factory.NewInterceptor("observer")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := observer.Close(); err != nil {
			t.Errorf("close observer: %v", err)
		}
	})

	forwarded := 0
	rtcpWriter := observer.BindRTCPWriter(interceptor.RTCPWriterFunc(func(
		packets []rtcp.Packet,
		_ interceptor.Attributes,
	) (int, error) {
		forwarded += len(packets)
		return len(packets), nil
	}))
	nacks := []rtcp.Packet{
		&rtcp.TransportLayerNack{
			MediaSSRC: 10,
			Nacks:     rtcp.NackPairsFromSequenceNumbers([]uint16{1, 2, 5}),
		},
		&rtcp.TransportLayerNack{
			MediaSSRC: 10,
			Nacks:     rtcp.NackPairsFromSequenceNumbers([]uint16{7, 8}),
		},
	}
	if _, err := rtcpWriter.Write(nacks, nil); err != nil {
		t.Fatal(err)
	}
	if forwarded != 2 {
		t.Fatalf("forwarded RTCP packets = %d", forwarded)
	}

	rawPackets := make(chan []byte, 5)
	rtpReader := observer.BindRemoteStream(
		&interceptor.StreamInfo{SSRC: 20, PayloadType: 46, MimeType: "video/rtx"},
		interceptor.RTPReaderFunc(func(
			buffer []byte,
			attributes interceptor.Attributes,
		) (int, interceptor.Attributes, error) {
			raw := <-rawPackets
			copy(buffer, raw)
			return len(raw), attributes, nil
		}),
	)
	if negotiated != 1 {
		t.Fatalf("RTX negotiated callbacks = %d", negotiated)
	}
	for _, originalSequence := range []uint16{2} {
		rawPackets <- marshalObserverRTX(t, originalSequence, 100+originalSequence)
		if _, _, err := rtpReader.Read(make([]byte, 1_500), nil); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := rtcpWriter.Write([]rtcp.Packet{&rtcp.TransportLayerNack{
		MediaSSRC: 10, Nacks: rtcp.NackPairsFromSequenceNumbers([]uint16{2}),
	}}, nil); err != nil {
		t.Fatal(err)
	}
	for _, originalSequence := range []uint16{2, 99} {
		rawPackets <- marshalObserverRTX(t, originalSequence, 100+originalSequence)
		if _, _, err := rtpReader.Read(make([]byte, 1_500), nil); err != nil {
			t.Fatal(err)
		}
	}
	rawPackets <- marshalObserverRTP(t, []byte{0xff}, 500)
	if _, _, err := rtpReader.Read(make([]byte, 1_500), nil); err != nil {
		t.Fatal(err)
	}

	snapshot := counters.Snapshot()
	if snapshot.NACKPacketsSent != 3 || snapshot.NACKSequencesSent != 6 ||
		snapshot.RTXPacketsReceived != 3 || snapshot.RTXBytesReceived != 45 ||
		snapshot.PacketsRepaired != 1 {
		t.Fatalf("observer snapshot = %#v", snapshot)
	}

	observer.UnbindRemoteStream(&interceptor.StreamInfo{SSRC: 20, MimeType: "video/rtx"})
	rawPackets <- marshalObserverRTX(t, 1, 600)
	if _, _, err := rtpReader.Read(make([]byte, 1_500), nil); err != nil {
		t.Fatal(err)
	}
	if got := counters.Snapshot(); got != snapshot {
		t.Fatalf("unbound observer changed counters: %#v", got)
	}
}

func TestRecoveryObserverCloseSuppressesNewBindings(t *testing.T) {
	counters := &RecoveryCounters{}
	negotiated := 0
	factory := NewRecoveryObserver(counters, func() { negotiated++ })
	observer, err := factory.NewInterceptor("closed-observer")
	if err != nil {
		t.Fatal(err)
	}
	if err := observer.Close(); err != nil {
		t.Fatal(err)
	}
	raw := marshalObserverRTX(t, 1, 1)
	reader := observer.BindRemoteStream(
		&interceptor.StreamInfo{SSRC: 20, PayloadType: 46, MimeType: "video/rtx"},
		interceptor.RTPReaderFunc(func(
			buffer []byte,
			attributes interceptor.Attributes,
		) (int, interceptor.Attributes, error) {
			copy(buffer, raw)
			return len(raw), attributes, nil
		}),
	)
	if _, _, err := reader.Read(make([]byte, 1_500), nil); err != nil {
		t.Fatal(err)
	}
	if negotiated != 0 || counters.Snapshot() != (RecoverySnapshot{}) {
		t.Fatalf("closed observer remained active: negotiated=%d stats=%#v", negotiated, counters.Snapshot())
	}
}

func TestRecoveryObserverMarksNegotiatedRTXFromLocalOrRemoteBindingOnce(t *testing.T) {
	negotiated := 0
	factory := NewRecoveryObserver(&RecoveryCounters{}, func() { negotiated++ })
	observer, err := factory.NewInterceptor("negotiation-observer")
	if err != nil {
		t.Fatal(err)
	}
	defer observer.Close()
	writer := interceptor.RTPWriterFunc(func(
		_ *rtp.Header,
		payload []byte,
		_ interceptor.Attributes,
	) (int, error) {
		return len(payload), nil
	})
	observer.BindLocalStream(&interceptor.StreamInfo{
		SSRC: 10, PayloadType: 45,
		SSRCRetransmission: 20, PayloadTypeRetransmission: 46,
		MimeType: "video/AV1",
	}, writer)
	if negotiated != 1 {
		t.Fatalf("local RTX binding callbacks = %d, want 1", negotiated)
	}
	observer.BindRemoteStream(
		&interceptor.StreamInfo{SSRC: 20, PayloadType: 46, MimeType: "video/rtx"},
		interceptor.RTPReaderFunc(func(
			_ []byte,
			attributes interceptor.Attributes,
		) (int, interceptor.Attributes, error) {
			return 0, attributes, nil
		}),
	)
	if negotiated != 1 {
		t.Fatalf("negotiated RTX callbacks = %d, want 1", negotiated)
	}
}

func marshalObserverRTX(t *testing.T, originalSequence, repairSequence uint16) []byte {
	t.Helper()
	return marshalObserverRTP(
		t,
		[]byte{byte(originalSequence >> 8), byte(originalSequence), 0xaa},
		repairSequence,
	)
}

func marshalObserverRTP(t *testing.T, payload []byte, sequence uint16) []byte {
	t.Helper()
	raw, err := (&rtp.Packet{
		Header: rtp.Header{
			Version: 2, PayloadType: 46, SequenceNumber: sequence,
			Timestamp: 90_000, SSRC: 20,
		},
		Payload: payload,
	}).Marshal()
	if err != nil {
		t.Fatal(err)
	}
	return raw
}
