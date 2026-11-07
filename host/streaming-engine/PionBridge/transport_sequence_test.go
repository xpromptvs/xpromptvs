package main

import (
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/rtp"
)

func TestTransportSequenceAllocatorWraps(t *testing.T) {
	allocator := newTransportSequenceAllocator(65_534)
	for index, expected := range []uint16{65_534, 65_535, 0, 1} {
		if actual := allocator.Next(); actual != expected {
			t.Fatalf("sequence %d = %d, want %d", index, actual, expected)
		}
	}
}

func TestTransportSequenceAllocatorConcurrentCallsAreUnique(t *testing.T) {
	allocator := newTransportSequenceAllocator(12_000)
	const count = 1_000
	values := make(chan uint16, count)
	var workers sync.WaitGroup
	for index := 0; index < count; index++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			values <- allocator.Next()
		}()
	}
	workers.Wait()
	close(values)
	seen := make(map[uint16]bool, count)
	for value := range values {
		if seen[value] {
			t.Fatalf("duplicate transport sequence %d", value)
		}
		seen[value] = true
	}
	if len(seen) != count {
		t.Fatalf("got %d unique sequences, want %d", len(seen), count)
	}
}

func TestTWCCHeaderInjectorAddsExtensionAndRecordsFinalPacket(t *testing.T) {
	now := time.Unix(10, 0)
	history := mustTWCCPacketHistory(t, TWCCPacketHistoryConfig{Now: func() time.Time { return now }})
	allocator := newTransportSequenceAllocator(65_535)
	factory := NewTWCCHeaderInjector(allocator, history)
	bound, err := factory.NewInterceptor("test")
	if err != nil {
		t.Fatal(err)
	}

	var written *rtp.Header
	child := interceptor.RTPWriterFunc(func(header *rtp.Header, payload []byte, _ interceptor.Attributes) (int, error) {
		copy := header.Clone()
		written = &copy
		return header.MarshalSize() + len(payload), nil
	})
	writer := bound.BindLocalStream(&interceptor.StreamInfo{
		SSRC: 41, SSRCRetransmission: 42,
		RTPHeaderExtensions: []interceptor.RTPHeaderExtension{{URI: twccURI, ID: 7}},
	}, child)
	header := &rtp.Header{Version: 2, SSRC: 42, SequenceNumber: 9}
	payload := []byte{1, 2, 3, 4}
	n, err := writer.Write(header, payload, nil)
	if err != nil {
		t.Fatal(err)
	}
	if n != written.MarshalSize()+len(payload) {
		t.Fatalf("write size = %d, want %d", n, written.MarshalSize()+len(payload))
	}
	var extension rtp.TransportCCExtension
	if err := extension.Unmarshal(written.GetExtension(7)); err != nil {
		t.Fatalf("decode TWCC extension: %v", err)
	}
	if extension.TransportSequence != 65_535 {
		t.Fatalf("transport sequence = %d", extension.TransportSequence)
	}
	snapshot := history.Snapshot()
	class := snapshot.ByClass[TWCCRTX]
	if class.SentPackets != 1 || class.SentBytes != uint64(n) {
		t.Fatalf("RTX snapshot = %+v, want one %d-byte packet", class, n)
	}
}

func TestTWCCHeaderInjectorRejectsMissingNegotiatedExtension(t *testing.T) {
	history := mustTWCCPacketHistory(t, TWCCPacketHistoryConfig{})
	factory := NewTWCCHeaderInjector(NewTransportSequenceAllocator(), history)
	bound, err := factory.NewInterceptor("test")
	if err != nil {
		t.Fatal(err)
	}
	writer := bound.BindLocalStream(&interceptor.StreamInfo{SSRC: 41}, interceptor.RTPWriterFunc(
		func(header *rtp.Header, payload []byte, _ interceptor.Attributes) (int, error) {
			return header.MarshalSize() + len(payload), nil
		},
	))
	_, err = writer.Write(&rtp.Header{Version: 2, SSRC: 41}, nil, nil)
	if !errors.Is(err, errTWCCExtensionNotNegotiated) {
		t.Fatalf("error = %v, want %v", err, errTWCCExtensionNotNegotiated)
	}
}

func TestTWCCHeaderInjectorSuppressesRecoveryBeforeAllocatingSequence(t *testing.T) {
	now := time.Unix(10, 0)
	history := mustTWCCPacketHistory(t, TWCCPacketHistoryConfig{Now: func() time.Time { return now }})
	allocator := newTransportSequenceAllocator(10)
	budget, err := NewRecoveryFrameClockBudget(RecoveryFrameClockBudgetConfig{
		RateBitsPerSecond: 8_000_000, FramesPerSecond: 60,
		BurstDuration: 20 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := budget.AdvanceFrame(1); err != nil {
		t.Fatal(err)
	}
	if err := budget.ObserveMedia(40_000); err != nil {
		t.Fatal(err)
	}
	factory := NewTWCCHeaderInjector(allocator, history, budget)
	bound, err := factory.NewInterceptor("test")
	if err != nil {
		t.Fatal(err)
	}
	writes := 0
	writer := bound.BindLocalStream(&interceptor.StreamInfo{
		SSRC: 41, SSRCRetransmission: 42,
		RTPHeaderExtensions: []interceptor.RTPHeaderExtension{{URI: twccURI, ID: 7}},
	}, interceptor.RTPWriterFunc(func(header *rtp.Header, payload []byte, _ interceptor.Attributes) (int, error) {
		writes++
		return header.MarshalSize() + len(payload), nil
	}))
	if _, err := writer.Write(&rtp.Header{Version: 2, SSRC: 42}, []byte{1}, nil); !errors.Is(err, errRecoveryFrameClockSuppressed) {
		t.Fatalf("RTX error = %v", err)
	}
	if writes != 0 || history.Snapshot().ByClass[TWCCRTX].SentPackets != 0 {
		t.Fatalf("suppressed RTX writes=%d history=%+v", writes, history.Snapshot())
	}
	if err := budget.AdvanceFrame(2); err != nil {
		t.Fatal(err)
	}
	if err := budget.AdvanceFrame(3); err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write(&rtp.Header{Version: 2, SSRC: 41}, []byte{1}, nil); err != nil {
		t.Fatal(err)
	}
	if writes != 1 {
		t.Fatalf("media writes = %d", writes)
	}
	if next := allocator.Next(); next != 11 {
		t.Fatalf("next sequence = %d, rejected recovery consumed a sequence", next)
	}
}
