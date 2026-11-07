package main

import (
	"encoding/binary"
	"net"
	"sync"
	"testing"
	"time"
)

// recordingConn records when each datagram reached the wire.
type recordingConn struct {
	net.PacketConn
	mu   sync.Mutex
	sent []time.Time
	size []int
}

func (c *recordingConn) WriteTo(p []byte, _ net.Addr) (int, error) {
	c.mu.Lock()
	c.sent = append(c.sent, time.Now())
	c.size = append(c.size, len(p))
	c.mu.Unlock()
	return len(p), nil
}
func (c *recordingConn) Close() error { return nil }
func (c *recordingConn) count() int   { c.mu.Lock(); defer c.mu.Unlock(); return len(c.sent) }

// THE TEST LINK SHAPES DTLS AT ITS RATE, PASSES RTP AND STUN AT ONCE, AND DROPS PAST ONE SECOND OF QUEUE.
func TestTheTestDataLinkShapesOnlyDTLS(t *testing.T) {
	inner := &recordingConn{}
	shaper := newTestDataLink(inner, testDataLinkConfig{bitsPerSecond: 80_000}) // 10 KB/s; the queue holds 16 KB (the floor)
	defer shaper.Close()

	rtp := make([]byte, 1200)
	rtp[0] = 0x80
	stun := make([]byte, 100)
	dtls := make([]byte, 1000)
	dtls[0] = 23 // application data

	start := time.Now()
	for i := 0; i < 5; i++ {
		_, _ = shaper.WriteTo(dtls, nil) // 5 KB: half a second at 10 KB/s
	}
	_, _ = shaper.WriteTo(rtp, nil)
	_, _ = shaper.WriteTo(stun, nil)
	time.Sleep(50 * time.Millisecond)
	if n := inner.count(); n < 2 || n > 3 {
		t.Fatalf("RTP and STUN must pass at once and DTLS be paced: %d datagram(s) out after 50 ms", n)
	}
	deadline := time.Now().Add(3 * time.Second)
	for inner.count() < 7 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if inner.count() != 7 {
		t.Fatalf("%d of 7 datagrams sent", inner.count())
	}
	took := inner.sent[len(inner.sent)-1].Sub(start)
	if took < 400*time.Millisecond || took > 900*time.Millisecond {
		t.Fatalf("5 KB of DTLS at 10 KB/s took %v; want ~500 ms", took)
	}

	// Past the 16 KB queue the bottleneck drops.
	for i := 0; i < 40; i++ {
		_, _ = shaper.WriteTo(dtls, nil)
	}
	shaper.mu.Lock()
	queued := len(shaper.queue)
	shaper.mu.Unlock()
	if queued > 16 {
		t.Fatalf("%d datagrams of 1000 B queued; the bottleneck holds 16 KB", queued)
	}
}

func TestTheTestDataLinkIsOffUnlessSet(t *testing.T) {
	for raw, want := range map[string]int{"": 0, "abc": 0, "-5": 0, "0": 0, " 100 ": 100} {
		if got := parseTestDataLinkKbps(raw); got != want {
			t.Fatalf("parseTestDataLinkKbps(%q) = %d, want %d", raw, got, want)
		}
	}
	for raw, want := range map[string]float64{"": 0, "x": 0, "-1": 0, "0": 0, "101": 0, "2": 0.02, " 0.5 ": 0.005, "100": 1} {
		if got := parseTestDataLinkPercent(raw); got != want {
			t.Fatalf("parseTestDataLinkPercent(%q) = %v, want %v", raw, got, want)
		}
	}
	for raw, want := range map[string]float64{"": 0, "1": 0, "0.5": 0, "x": 0, "4": 4, " 2.5 ": 2.5} {
		if got := parseTestDataLinkBurst(raw); got != want {
			t.Fatalf("parseTestDataLinkBurst(%q) = %v, want %v", raw, got, want)
		}
	}
	if testDataLinkFromEnvironment(func(string) string { return "" }).active() {
		t.Fatal("an empty environment must wrap nothing")
	}
	config := testDataLinkFromEnvironment(func(name string) string {
		return map[string]string{
			"RDEV_TEST_DATA_LINK_RTT_MS": "80", "RDEV_TEST_DATA_LINK_LOSS_IN": "5", "RDEV_TEST_DATA_LINK_LOSS_OUT": "2",
			"RDEV_TEST_DATA_LINK_SEED": "7",
		}[name]
	})
	if !config.active() || config.delay != 80*time.Millisecond || config.lossIn != 0.05 || config.lossOut != 0.02 || config.seed != 7 {
		t.Fatalf("parsed %+v", config)
	}
}

// THE DELAY HOLDS EVERY DTLS RECORD FOR IT, IN ORDER, AND NOTHING ELSE.
func TestTheTestDataLinkDelaysOnlyDTLS(t *testing.T) {
	inner := &recordingConn{}
	link := newTestDataLink(inner, testDataLinkConfig{delay: 150 * time.Millisecond})
	defer link.Close()

	start := time.Now()
	for i := 0; i < 3; i++ {
		record := []byte{22, byte(i)} // a handshake record: delayed, never lost
		_, _ = link.WriteTo(record, nil)
	}
	_, _ = link.WriteTo([]byte{0x80, 0}, nil) // RTP
	_, _ = link.WriteTo([]byte{0, 1}, nil)    // STUN
	time.Sleep(50 * time.Millisecond)
	if n := inner.count(); n != 2 {
		t.Fatalf("RTP and STUN must pass at once and DTLS wait out the delay: %d datagram(s) out after 50 ms", n)
	}
	deadline := time.Now().Add(2 * time.Second)
	for inner.count() < 5 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if inner.count() != 5 {
		t.Fatalf("%d of 5 datagrams sent", inner.count())
	}
	for i := 2; i < 5; i++ {
		if took := inner.sent[i].Sub(start); took < 150*time.Millisecond || took > 400*time.Millisecond {
			t.Fatalf("DTLS record %d crossed in %v; want the 150 ms delay", i-2, took)
		}
	}
}

// LOSS ON THE WAY OUT: application data at the configured rate; the handshake, RTP and STUN never.
func TestTheTestDataLinkLosesOutgoingApplicationDataAtItsRate(t *testing.T) {
	inner := &recordingConn{}
	link := newTestDataLink(inner, testDataLinkConfig{lossOut: 0.05, seed: 1})
	defer link.Close()

	const n = 20_000
	for i := 0; i < n; i++ {
		_, _ = link.WriteTo([]byte{23, 1, 2}, nil)
	}
	dropped := n - inner.count()
	if dropped < n*4/100 || dropped > n*6/100 {
		t.Fatalf("%d of %d application-data records dropped; want ~5%%", dropped, n)
	}
	before := inner.count()
	for i := 0; i < 1000; i++ {
		_, _ = link.WriteTo([]byte{22, 1}, nil)   // handshake
		_, _ = link.WriteTo([]byte{0x80, 1}, nil) // RTP
		_, _ = link.WriteTo([]byte{1, 1}, nil)    // STUN
	}
	if got := inner.count() - before; got != 3000 {
		t.Fatalf("%d of 3000 handshake/RTP/STUN datagrams sent; none may be lost", got)
	}
	if in, out := link.counts(); out.records != n || out.dropped != uint64(dropped) || in.records != 0 {
		t.Fatalf("counted in %+v out %+v", in, out)
	}
}

func (link *testDataLink) counts() (dataLinkDirection, dataLinkDirection) {
	link.mu.Lock()
	defer link.mu.Unlock()
	return link.in, link.out
}

// scriptedConn hands out datagrams one by one, then an error.
type scriptedConn struct {
	net.PacketConn
	datagrams [][]byte
}

func (c *scriptedConn) ReadFrom(p []byte) (int, net.Addr, error) {
	if len(c.datagrams) == 0 {
		return 0, nil, net.ErrClosed
	}
	d := c.datagrams[0]
	c.datagrams = c.datagrams[1:]
	return copy(p, d), nil, nil
}
func (c *scriptedConn) Close() error { return nil }

// LOSS ON THE WAY IN: a lost record never reaches the reader; what follows it does.
func TestTheTestDataLinkLosesIncomingApplicationDataAtItsRate(t *testing.T) {
	const n = 20_000
	inner := &scriptedConn{}
	for i := 0; i < n; i++ {
		inner.datagrams = append(inner.datagrams, []byte{23, 9}, []byte{22, 9}, []byte{0x80, 9}, []byte{1, 9})
	}
	link := newTestDataLink(inner, testDataLinkConfig{lossIn: 0.05, seed: 1})
	defer link.Close()

	var applicationData, other int
	buffer := make([]byte, 64)
	for {
		size, _, err := link.ReadFrom(buffer)
		if err != nil {
			break
		}
		if size == 2 && buffer[0] == 23 {
			applicationData++
		} else {
			other++
		}
	}
	if dropped := n - applicationData; dropped < n*4/100 || dropped > n*6/100 {
		t.Fatalf("%d of %d incoming application-data records dropped; want ~5%%", dropped, n)
	}
	if other != 3*n {
		t.Fatalf("%d of %d handshake/RTP/STUN datagrams read; none may be lost", other, 3*n)
	}
	if in, out := link.counts(); in.records != n || out.records != 0 {
		t.Fatalf("counted in %+v out %+v", in, out)
	}
}

// dataLinkCapturingConn keeps every datagram written to it.
type dataLinkCapturingConn struct {
	net.PacketConn
	mu  sync.Mutex
	got [][]byte
}

func (c *dataLinkCapturingConn) WriteTo(p []byte, _ net.Addr) (int, error) {
	c.mu.Lock()
	c.got = append(c.got, append([]byte(nil), p...))
	c.mu.Unlock()
	return len(p), nil
}
func (c *dataLinkCapturingConn) Close() error { return nil }

// BURSTS (Gilbert–Elliott): the configured share is lost, in runs averaging the configured length — what Wi-Fi and
// cellular do, and what hits both a packet and its repair (docs/superpowers/specs/2026-10-12-terminal-lane-design.md §5).
func TestTheTestDataLinkLosesInBursts(t *testing.T) {
	inner := &dataLinkCapturingConn{}
	link := newTestDataLink(inner, testDataLinkConfig{lossOut: 0.05, burst: 4, seed: 1})
	defer link.Close()
	const n = 200_000
	for i := 0; i < n; i++ {
		record := []byte{23, 0, 0, 0, 0}
		binary.BigEndian.PutUint32(record[1:], uint32(i))
		_, _ = link.WriteTo(record, nil)
	}
	sent := make(map[uint32]bool, n)
	for _, r := range inner.got {
		sent[binary.BigEndian.Uint32(r[1:])] = true
	}
	dropped, runs := 0, 0
	for i := 0; i < n; i++ {
		if !sent[uint32(i)] {
			dropped++
			if i == 0 || sent[uint32(i-1)] {
				runs++
			}
		}
	}
	if share := float64(dropped) / n; share < 0.04 || share > 0.06 {
		t.Fatalf("dropped %.1f%%; want ~5%%", share*100)
	}
	if mean := float64(dropped) / float64(runs); mean < 3 || mean > 5 {
		t.Fatalf("losses came in runs of %.1f on average; want ~4", mean)
	}
}
