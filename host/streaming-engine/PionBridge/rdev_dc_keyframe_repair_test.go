package main

import (
	"encoding/binary"
	"testing"
)

// Decode the window a repair packet covers: [firstESI, firstESI+windowLen).
func repairWindow(packet []byte) (first uint32, length int) {
	return binary.LittleEndian.Uint32(packet[8:]), int(binary.LittleEndian.Uint16(packet[12:]))
}

func sourceESI(packet []byte) uint32 { return binary.LittleEndian.Uint32(packet[8:]) }

// EVERY SOURCE SYMBOL MUST BE INSIDE SOME REPAIR'S WINDOW. This is the property the old emission
// could not satisfy and no repair COUNT could have fixed.
//
// `buildRepair` combines the encoder's CURRENT window — the last 16 symbols. Emitting every repair
// after the final source symbol therefore protects only the final 16 of them. Measured against a real
// keyframe of 39 symbols (45.7 kB on the wire), the first 23 were covered by nothing: not by that
// frame's repairs, which had slid past them, and not by any later frame's, whose window has moved on.
func TestEverySymbolOfALargeKeyframeIsCoveredByARepair(t *testing.T) {
	stream := newDCVideoStream(0, 16, 1, 2)
	stream.setRepairRate(0.05)

	// 39 symbols, the size the host's own [frames] line reported for a real keyframe.
	packets := stream.packetsFor(make([]byte, 39*dcSymbolBytes), 0, true, 45, 0)

	covered := map[uint32]bool{}
	var sources []uint32
	for _, packet := range packets {
		if packet[5] == dcKindSource {
			sources = append(sources, sourceESI(packet))
			continue
		}
		first, length := repairWindow(packet)
		for esi := first; esi < first+uint32(length); esi++ {
			covered[esi] = true
		}
	}
	if len(sources) != 39 {
		t.Fatalf("emitted %d source symbols, want 39", len(sources))
	}
	for _, esi := range sources {
		if !covered[esi] {
			t.Fatalf("source symbol ESI %d is covered by NO repair — a loss there is unrecoverable", esi)
		}
	}
}

// AND THE REPAIRS ARE SPREAD, not appended. The coverage above is achieved by interleaving; a run of
// repairs at the tail cannot reach the head of a frame longer than the window however many there are.
func TestKeyframeRepairsAreInterleavedWithTheFrame(t *testing.T) {
	stream := newDCVideoStream(0, 16, 1, 2)
	packets := stream.packetsFor(make([]byte, 39*dcSymbolBytes), 0, true, 45, 0)

	lastSource := -1
	firstRepair := -1
	for i, packet := range packets {
		if packet[5] == dcKindSource {
			lastSource = i
		} else if firstRepair < 0 {
			firstRepair = i
		}
	}
	if firstRepair < 0 {
		t.Fatal("no repair symbols at all")
	}
	if firstRepair > lastSource {
		t.Fatal("every repair came after every source symbol — the head of the frame is unprotected")
	}
}

// THE COUNT SCALES WITH THE FRAME. A flat two symbols over 39 is 4.9% tolerance on the one frame the
// whole recovery path depends on, while the three-symbol delta frames around it were getting the full
// adaptive rate.
func TestKeyframeRepairScalesWithSize(t *testing.T) {
	stream := newDCVideoStream(0, 16, 1, 2)
	stream.setRepairRate(0.05)
	packets := stream.packetsFor(make([]byte, 40*dcSymbolBytes), 0, true, 45, 0)

	repairs := 0
	for _, packet := range packets {
		if packet[5] == dcKindRepair {
			repairs++
		}
	}
	// 40 symbols at the keyframe rate of 0.5.
	if repairs < 18 || repairs > 22 {
		t.Fatalf("a 40-symbol keyframe earned %d repair symbols, want ~20 (half its size)", repairs)
	}
}

// A SMALL KEYFRAME STILL GETS THE FLOOR, so the rate cannot take protection away from the frames that
// were already covered.
func TestSmallKeyframeKeepsTheFloor(t *testing.T) {
	stream := newDCVideoStream(0, 16, 1, 2)
	stream.setRepairRate(0.0)
	packets := stream.packetsFor(make([]byte, 300), 0, true, 45, 0)
	repairs := 0
	for _, packet := range packets {
		if packet[5] == dcKindRepair {
			repairs++
		}
	}
	if repairs < 2 {
		t.Fatalf("a one-symbol keyframe earned %d repair symbols, want at least the floor of 2", repairs)
	}
}

// DELTA FRAMES ARE UNTOUCHED. The keyframe rate must not leak into ordinary frames — 5% on a clean
// link is a promise this change is not allowed to break.
func TestDeltaFramesKeepTheirRate(t *testing.T) {
	stream := newDCVideoStream(0, 16, 1, 2)
	stream.setRepairRate(0.05)
	repairs := 0
	for i := 0; i < 200; i++ {
		for _, packet := range stream.packetsFor(make([]byte, 300), 0, false, 45, 1) {
			if packet[5] == dcKindRepair {
				repairs++
			}
		}
	}
	if repairs < 8 || repairs > 13 {
		t.Fatalf("emitted %d repair symbols over 200 delta frames, want ~10 (5%%)", repairs)
	}
}

// EVERY SYMBOL OF A DELTA FRAME IS COVERED TOO — the interleave must not have moved the single repair
// a small frame earns to a place where it misses part of that frame.
func TestEverySymbolOfAMultiSymbolDeltaFrameIsCovered(t *testing.T) {
	stream := newDCVideoStream(0, 16, 1, 2)
	stream.setRepairRate(0.5)
	packets := stream.packetsFor(make([]byte, 6*dcSymbolBytes), 0, false, 45, 1)

	covered := map[uint32]bool{}
	var sources []uint32
	for _, packet := range packets {
		if packet[5] == dcKindSource {
			sources = append(sources, sourceESI(packet))
			continue
		}
		first, length := repairWindow(packet)
		for esi := first; esi < first+uint32(length); esi++ {
			covered[esi] = true
		}
	}
	for _, esi := range sources {
		if !covered[esi] {
			t.Fatalf("delta symbol ESI %d is covered by no repair", esi)
		}
	}
}
