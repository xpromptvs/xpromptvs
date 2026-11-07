package main

import (
	"encoding/binary"
	"errors"
)

// THE LANE'S WIRE FORMAT (docs/superpowers/specs/2026-10-12-terminal-lane-design.md §2), mirrored byte for byte by
// web/src/lib/lane-codec.ts and held to protocol/fixtures/lane-vectors.json (scripts/gen_lane_vectors.py).
const (
	// One data-channel message, one SCTP packet on BOTH stacks: the smaller MTU is Chrome's dcsctp (1191 − 32 of
	// SCTP headers). A message split across packets is lost when any one is, and nothing re-sends it.
	lanePacketMax   = 1100
	laneHeaderBytes = 9
	// A symbol INCLUDING its 2-byte length prefix — a REPAIR over full symbols is 19 + 1080 bytes.
	laneSymbolMax   = 1080
	laneChunkHeader = 7
	laneRangesMax   = 16

	laneTypeSource   = 1
	laneTypeRepair   = 2
	laneTypeFeedback = 3

	laneStreams = 3 // terminal 0, input 1, control 2 — the ABI's channel slots
)

var errLaneMalformed = errors.New("lane: malformed packet or symbol")

type laneRange struct {
	start  uint32
	length uint16
}

type laneFeedback struct {
	cumESI       uint32 // every ESI below is decoded
	ranges       []laneRange
	lossPermille uint16
	echoTS       uint32 // the ts of the newest packet received
	held         uint16 // ms between receiving that packet and sending this
}

type lanePacket struct {
	kind     byte
	pkt      uint32
	ts       uint32
	esi      uint32 // SOURCE's ESI; REPAIR's first ESI
	count    uint16 // REPAIR
	seed     uint32 // REPAIR
	payload  []byte // SOURCE's symbol; REPAIR's combined bytes
	feedback laneFeedback
}

type laneChunk struct {
	stream byte
	offset uint32
	bytes  []byte
}

func laneHeader(kind byte, pkt, ts uint32, size int) []byte {
	out := make([]byte, laneHeaderBytes, size)
	out[0] = kind
	binary.BigEndian.PutUint32(out[1:5], pkt)
	binary.BigEndian.PutUint32(out[5:9], ts)
	return out
}

func encodeLaneSource(pkt, ts, esi uint32, symbol []byte) []byte {
	out := laneHeader(laneTypeSource, pkt, ts, laneHeaderBytes+4+len(symbol))
	out = binary.BigEndian.AppendUint32(out, esi)
	return append(out, symbol...)
}

func encodeLaneRepair(pkt, ts, firstESI uint32, count uint16, seed uint32, payload []byte) []byte {
	out := laneHeader(laneTypeRepair, pkt, ts, laneHeaderBytes+10+len(payload))
	out = binary.BigEndian.AppendUint32(out, firstESI)
	out = binary.BigEndian.AppendUint16(out, count)
	out = binary.BigEndian.AppendUint32(out, seed)
	return append(out, payload...)
}

func encodeLaneFeedback(pkt, ts uint32, f laneFeedback) []byte {
	out := laneHeader(laneTypeFeedback, pkt, ts, laneHeaderBytes+5+6*len(f.ranges)+8)
	out = binary.BigEndian.AppendUint32(out, f.cumESI)
	out = append(out, byte(len(f.ranges)))
	for _, r := range f.ranges {
		out = binary.BigEndian.AppendUint32(out, r.start)
		out = binary.BigEndian.AppendUint16(out, r.length)
	}
	out = binary.BigEndian.AppendUint16(out, f.lossPermille)
	out = binary.BigEndian.AppendUint32(out, f.echoTS)
	return binary.BigEndian.AppendUint16(out, f.held)
}

// decodeLanePacket parses one lane packet; payloads are COPIED (pion reuses its read buffer).
func decodeLanePacket(b []byte) (lanePacket, error) {
	var p lanePacket
	if len(b) < laneHeaderBytes || len(b) > lanePacketMax {
		return p, errLaneMalformed
	}
	p.kind = b[0]
	p.pkt = binary.BigEndian.Uint32(b[1:5])
	p.ts = binary.BigEndian.Uint32(b[5:9])
	body := b[laneHeaderBytes:]
	switch p.kind {
	case laneTypeSource:
		if len(body) < 4+2 || len(body)-4 > laneSymbolMax {
			return p, errLaneMalformed
		}
		p.esi = binary.BigEndian.Uint32(body[0:4])
		p.payload = append([]byte(nil), body[4:]...)
	case laneTypeRepair:
		if len(body) < 10+2 || len(body)-10 > laneSymbolMax {
			return p, errLaneMalformed
		}
		p.esi = binary.BigEndian.Uint32(body[0:4])
		p.count = binary.BigEndian.Uint16(body[4:6])
		p.seed = binary.BigEndian.Uint32(body[6:10])
		if p.count == 0 {
			return p, errLaneMalformed
		}
		p.payload = append([]byte(nil), body[10:]...)
	case laneTypeFeedback:
		if len(body) < 5 {
			return p, errLaneMalformed
		}
		n := int(body[4])
		if n > laneRangesMax || len(body) != 5+6*n+8 {
			return p, errLaneMalformed
		}
		f := &p.feedback
		f.cumESI = binary.BigEndian.Uint32(body[0:4])
		at := 5
		for i := 0; i < n; i++ {
			f.ranges = append(f.ranges, laneRange{binary.BigEndian.Uint32(body[at:]), binary.BigEndian.Uint16(body[at+4:])})
			at += 6
		}
		f.lossPermille = binary.BigEndian.Uint16(body[at:])
		f.echoTS = binary.BigEndian.Uint32(body[at+2:])
		f.held = binary.BigEndian.Uint16(body[at+6:])
	default:
		return p, errLaneMalformed
	}
	return p, nil
}

// buildLaneSymbol lays chunks out as a symbol: `len u16` (the chunk bytes that follow), then each chunk.
func buildLaneSymbol(chunks []laneChunk) []byte {
	size := 0
	for _, c := range chunks {
		size += laneChunkHeader + len(c.bytes)
	}
	out := make([]byte, 2, 2+size)
	binary.BigEndian.PutUint16(out, uint16(size))
	for _, c := range chunks {
		out = append(out, c.stream)
		out = binary.BigEndian.AppendUint32(out, c.offset)
		out = binary.BigEndian.AppendUint16(out, uint16(len(c.bytes)))
		out = append(out, c.bytes...)
	}
	return out
}

// parseLaneSymbol reads a symbol back — from a SOURCE packet, or rebuilt from repair and so zero-padded past its
// length, which the prefix makes harmless.
func parseLaneSymbol(symbol []byte) ([]laneChunk, error) {
	if len(symbol) < 2 {
		return nil, errLaneMalformed
	}
	size := int(binary.BigEndian.Uint16(symbol))
	if 2+size > len(symbol) {
		return nil, errLaneMalformed
	}
	body := symbol[2 : 2+size]
	var chunks []laneChunk
	for len(body) > 0 {
		if len(body) < laneChunkHeader {
			return nil, errLaneMalformed
		}
		length := int(binary.BigEndian.Uint16(body[5:7]))
		if body[0] >= laneStreams || laneChunkHeader+length > len(body) {
			return nil, errLaneMalformed
		}
		chunks = append(chunks, laneChunk{
			stream: body[0], offset: binary.BigEndian.Uint32(body[1:5]),
			bytes: append([]byte(nil), body[laneChunkHeader:laneChunkHeader+length]...),
		})
		body = body[laneChunkHeader+length:]
	}
	return chunks, nil
}

// unwrapLane32 is the 64-bit counter nearest `reference` whose low 32 bits are `wire`: how a receiver reads a
// counter the wire carries in 32 bits. The live window is far smaller than 2³¹, so the nearest is the one meant.
func unwrapLane32(reference uint64, wire uint32) uint64 {
	candidate := reference&^0xffffffff | uint64(wire)
	if candidate > reference && candidate-reference > 1<<31 && candidate >= 1<<32 {
		return candidate - 1<<32
	}
	if candidate < reference && reference-candidate > 1<<31 {
		return candidate + 1<<32
	}
	return candidate
}
