package main

import "sync/atomic"

type ResponderCacheSnapshot struct {
	PacketsCurrent uint64 `json:"packetsCurrent"`
	PacketsPeak    uint64 `json:"packetsPeak"`
	BytesCurrent   uint64 `json:"bytesCurrent"`
	BytesPeak      uint64 `json:"bytesPeak"`
}

type ResponderCacheCounters struct {
	packetsCurrent atomic.Int64
	packetsPeak    atomic.Uint64
	bytesCurrent   atomic.Int64
	bytesPeak      atomic.Uint64
}

func (counters *ResponderCacheCounters) adjust(packetDelta, byteDelta int64) {
	packets := counters.packetsCurrent.Add(packetDelta)
	bytes := counters.bytesCurrent.Add(byteDelta)
	if packets < 0 || bytes < 0 {
		panic("recovery responder cache counter underflow")
	}
	updateResponderCachePeak(&counters.packetsPeak, uint64(packets))
	updateResponderCachePeak(&counters.bytesPeak, uint64(bytes))
}

func (counters *ResponderCacheCounters) Snapshot() ResponderCacheSnapshot {
	packets := counters.packetsCurrent.Load()
	bytes := counters.bytesCurrent.Load()
	if packets < 0 || bytes < 0 {
		panic("recovery responder cache counter underflow")
	}
	return ResponderCacheSnapshot{
		PacketsCurrent: uint64(packets),
		PacketsPeak:    counters.packetsPeak.Load(),
		BytesCurrent:   uint64(bytes),
		BytesPeak:      counters.bytesPeak.Load(),
	}
}

func updateResponderCachePeak(peak *atomic.Uint64, current uint64) {
	for previous := peak.Load(); current > previous; previous = peak.Load() {
		if peak.CompareAndSwap(previous, current) {
			return
		}
	}
}
