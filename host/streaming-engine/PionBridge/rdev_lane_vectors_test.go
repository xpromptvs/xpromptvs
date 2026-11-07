package main

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"
)

// THE LANE AGAINST A THIRD IMPLEMENTATION (scripts/gen_lane_vectors.py → protocol/fixtures/lane-vectors.json).
// web/test/lane-vectors.test.ts asserts the same file. Never edit the file by hand to pass.
type laneVectorFile struct {
	Coefficients []struct {
		Seed   uint32 `json:"seed"`
		Values []int  `json:"values"`
	} `json:"coefficients"`
	NextSeed []struct {
		Seed uint32 `json:"seed"`
		Next uint32 `json:"next"`
	} `json:"nextSeed"`
	RLC []struct {
		Name    string   `json:"name"`
		Seed    uint32   `json:"seed"`
		Symbols []string `json:"symbols"`
		Repair  string   `json:"repair"`
	} `json:"rlc"`
	Packets          []laneVectorPacket `json:"packets"`
	MalformedPackets []laneVectorBytes  `json:"malformedPackets"`
	Symbols          []struct {
		Name   string `json:"name"`
		Chunks []struct {
			Stream byte   `json:"stream"`
			Offset uint32 `json:"offset"`
			Bytes  string `json:"bytes"`
		} `json:"chunks"`
		Bytes string `json:"bytes"`
	} `json:"symbols"`
	MalformedSymbols []laneVectorBytes `json:"malformedSymbols"`
	Unwrap           []struct {
		Reference uint64 `json:"reference"`
		Wire      uint32 `json:"wire"`
		Full      uint64 `json:"full"`
	} `json:"unwrap"`
}

type laneVectorBytes struct {
	Name  string `json:"name"`
	Bytes string `json:"bytes"`
}

type laneVectorPacket struct {
	Name         string      `json:"name"`
	Kind         string      `json:"kind"`
	Bytes        string      `json:"bytes"`
	Pkt          uint32      `json:"pkt"`
	TS           uint32      `json:"ts"`
	ESI          uint32      `json:"esi"`
	Symbol       string      `json:"symbol"`
	FirstESI     uint32      `json:"firstEsi"`
	Count        uint16      `json:"count"`
	Seed         uint32      `json:"seed"`
	Payload      string      `json:"payload"`
	CumESI       uint32      `json:"cumEsi"`
	Ranges       [][2]uint32 `json:"ranges"`
	LossPermille uint16      `json:"lossPermille"`
	EchoTS       uint32      `json:"echoTs"`
	Held         uint16      `json:"held"`
}

func loadLaneVectors(t *testing.T) laneVectorFile {
	t.Helper()
	// rules_go runs a test in its package directory; the fixture is a declared data dependency (//protocol:fixtures).
	raw, err := os.ReadFile("../../../protocol/fixtures/lane-vectors.json")
	if err != nil {
		t.Fatalf("read the lane vectors (python3 scripts/gen_lane_vectors.py writes them): %v", err)
	}
	var v laneVectorFile
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatalf("parse the lane vectors: %v", err)
	}
	if len(v.RLC) == 0 || len(v.Packets) == 0 || len(v.Symbols) == 0 || len(v.Unwrap) == 0 || len(v.NextSeed) == 0 ||
		len(v.Coefficients) == 0 || len(v.MalformedPackets) == 0 || len(v.MalformedSymbols) == 0 {
		t.Fatal("an empty vector list would pass every assertion below")
	}
	return v
}

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatalf("bad hex %q: %v", s, err)
	}
	return b
}

func TestLaneVectorsCoefficientsAndSeeds(t *testing.T) {
	v := loadLaneVectors(t)
	for _, c := range v.Coefficients {
		got := make([]byte, len(c.Values))
		rlcCoefficients(c.Seed, got)
		for i := range got {
			if int(got[i]) != c.Values[i] {
				t.Fatalf("rlcCoefficients(%#x) = %v, want %v", c.Seed, got, c.Values)
			}
		}
	}
	for _, s := range v.NextSeed {
		if got := rlcNextSeed(s.Seed); got != s.Next {
			t.Fatalf("rlcNextSeed(%#x) = %#x, want %#x", s.Seed, got, s.Next)
		}
	}
}

func TestLaneVectorsRepairAndRecover(t *testing.T) {
	v := loadLaneVectors(t)
	for _, r := range v.RLC {
		symbols := make([][]byte, len(r.Symbols))
		for i, s := range r.Symbols {
			symbols[i] = mustHex(t, s)
		}
		want := mustHex(t, r.Repair)
		if got := rlcRepair(symbols, r.Seed); !bytes.Equal(got, want) {
			t.Fatalf("%s: rlcRepair = %x, want %x", r.Name, got, want)
		}
		// And the decoder rebuilds the LAST symbol from the others plus the third implementation's repair.
		d := newRLCDecoder(1024)
		lost := len(symbols) - 1
		for i, s := range symbols[:lost] {
			d.addSource(uint64(i), padLane(s))
		}
		d.addRepair(0, len(symbols), r.Seed, padLane(want))
		if !bytes.Equal(d.get(uint64(lost)), padLane(symbols[lost])) {
			t.Fatalf("%s: recovered %x, want %x", r.Name, d.get(uint64(lost)), padLane(symbols[lost]))
		}
	}
}

func TestLaneVectorsPackets(t *testing.T) {
	v := loadLaneVectors(t)
	for _, p := range v.Packets {
		want := mustHex(t, p.Bytes)
		var got []byte
		switch p.Kind {
		case "source":
			got = encodeLaneSource(p.Pkt, p.TS, p.ESI, mustHex(t, p.Symbol))
		case "repair":
			got = encodeLaneRepair(p.Pkt, p.TS, p.FirstESI, p.Count, p.Seed, mustHex(t, p.Payload))
		case "feedback":
			f := laneFeedback{cumESI: p.CumESI, lossPermille: p.LossPermille, echoTS: p.EchoTS, held: p.Held}
			for _, r := range p.Ranges {
				f.ranges = append(f.ranges, laneRange{r[0], uint16(r[1])})
			}
			got = encodeLaneFeedback(p.Pkt, p.TS, f)
		default:
			t.Fatalf("%s: unknown kind %q", p.Name, p.Kind)
		}
		if !bytes.Equal(got, want) {
			t.Fatalf("%s: encoded %x, want %x", p.Name, got, want)
		}
		d, err := decodeLanePacket(want)
		if err != nil {
			t.Fatalf("%s: %v", p.Name, err)
		}
		if d.pkt != p.Pkt || d.ts != p.TS {
			t.Fatalf("%s: header pkt %d ts %d", p.Name, d.pkt, d.ts)
		}
		switch p.Kind {
		case "source":
			if d.kind != laneTypeSource || d.esi != p.ESI || !bytes.Equal(d.payload, mustHex(t, p.Symbol)) {
				t.Fatalf("%s: decoded %+v", p.Name, d)
			}
		case "repair":
			if d.kind != laneTypeRepair || d.esi != p.FirstESI || d.count != p.Count || d.seed != p.Seed ||
				!bytes.Equal(d.payload, mustHex(t, p.Payload)) {
				t.Fatalf("%s: decoded %+v", p.Name, d)
			}
		case "feedback":
			f := d.feedback
			if d.kind != laneTypeFeedback || f.cumESI != p.CumESI || f.lossPermille != p.LossPermille ||
				f.echoTS != p.EchoTS || f.held != p.Held || len(f.ranges) != len(p.Ranges) {
				t.Fatalf("%s: decoded %+v", p.Name, f)
			}
			for i, r := range p.Ranges {
				if f.ranges[i] != (laneRange{r[0], uint16(r[1])}) {
					t.Fatalf("%s: range %d = %+v, want %v", p.Name, i, f.ranges[i], r)
				}
			}
		}
	}
	for _, m := range v.MalformedPackets {
		if _, err := decodeLanePacket(mustHex(t, m.Bytes)); err == nil {
			t.Fatalf("accepted a malformed packet: %s", m.Name)
		}
	}
}

func TestLaneVectorsSymbols(t *testing.T) {
	v := loadLaneVectors(t)
	for _, s := range v.Symbols {
		var chunks []laneChunk
		for _, c := range s.Chunks {
			chunks = append(chunks, laneChunk{c.Stream, c.Offset, mustHex(t, c.Bytes)})
		}
		raw := mustHex(t, s.Bytes)
		parsed, err := parseLaneSymbol(raw)
		if err != nil {
			t.Fatalf("%s: %v", s.Name, err)
		}
		if len(parsed) != len(chunks) {
			t.Fatalf("%s: %d chunks, want %d", s.Name, len(parsed), len(chunks))
		}
		for i := range chunks {
			if parsed[i].stream != chunks[i].stream || parsed[i].offset != chunks[i].offset ||
				!bytes.Equal(parsed[i].bytes, chunks[i].bytes) {
				t.Fatalf("%s: chunk %d = %+v, want %+v", s.Name, i, parsed[i], chunks[i])
			}
		}
		// Building gives the bytes back — up to the zero padding a symbol rebuilt from repair carries.
		built := buildLaneSymbol(chunks)
		if !bytes.Equal(built, raw[:len(built)]) || !bytes.Equal(raw[len(built):], make([]byte, len(raw)-len(built))) {
			t.Fatalf("%s: built %x, want %x", s.Name, built, raw)
		}
	}
	for _, m := range v.MalformedSymbols {
		if _, err := parseLaneSymbol(mustHex(t, m.Bytes)); err == nil {
			t.Fatalf("accepted a malformed symbol: %s", m.Name)
		}
	}
}

func TestLaneVectorsUnwrap(t *testing.T) {
	v := loadLaneVectors(t)
	for _, u := range v.Unwrap {
		if got := unwrapLane32(u.Reference, u.Wire); got != u.Full {
			t.Fatalf("unwrapLane32(%d, %#x) = %d, want %d", u.Reference, u.Wire, got, u.Full)
		}
	}
}
