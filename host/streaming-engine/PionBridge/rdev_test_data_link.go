package main

import (
	"fmt"
	"math/rand"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// RDEV_TEST_DATA_LINK_* — A TEST LINK FOR THE DATA CHANNELS, AND ONLY FOR THEM (TEST knobs; docs/bring-up.md).
//
// The host's DTLS records — the datagrams that carry SCTP, so every data channel on the association (`lane`, `bulk`;
// the SCTP baseline's four) — cross a simulated link:
//
//	RDEV_TEST_DATA_LINK_KBPS      a bottleneck of this many kbit/s on the way OUT, with a FIFO of one second of it (at
//	                              least 16 KB), dropped at the tail beyond that, as a router's buffer does
//	RDEV_TEST_DATA_LINK_RTT_MS    this much added to the data channels' round trip, all of it on the way OUT: a
//	                              keystroke's echo, and every retransmission timer, sees the whole round trip wherever
//	                              it sits, so the split changes no measurement
//	RDEV_TEST_DATA_LINK_LOSS_IN   percent of the client's records dropped on the way IN (keystrokes, and the SACKs for
//	                              what the host sent)
//	RDEV_TEST_DATA_LINK_LOSS_OUT  percent of the host's records dropped on the way OUT (terminal output, replies)
//	RDEV_TEST_DATA_LINK_SEED      the loss's random seed (default 1), so a run can be repeated
//	RDEV_TEST_DATA_LINK_BURST     loss in BURSTS averaging this many records (Gilbert–Elliott: every record in the
//	                              bad state is lost, and the bad state's share is the loss); unset or ≤ 1, independent
//
// Loss is independent per datagram unless BURST is set, and touches only APPLICATION DATA (first byte 23), so the DTLS
// handshake crosses whole. RTP and RTCP (first byte 128–191) pass untouched: the test pattern's video would otherwise
// fill the link and every terminal number would measure the video. STUN (0–3) passes too, so ICE stays up — and the
// ICE round trip the client reads stays loopback's, so predictive echo (gated on it) stays off and a check measures
// the echo itself.
//
// It exists to measure what a phone on a slow or lossy link sees of the terminal (docs/terminal.md, "A slow link gets
// the terminal paced", "What a lost packet costs the terminal"), which nothing on loopback can produce. Unset — the
// product — nothing is wrapped. They are environment variables, not an ABI addition, for the reason
// RDEV_LLV_IMPAIRMENT_PROFILE gives above.
var testDataLinkSettings = testDataLinkFromEnvironment(os.Getenv)

type testDataLinkConfig struct {
	bitsPerSecond int
	delay         time.Duration
	lossIn        float64 // probability, 0…1
	lossOut       float64
	seed          int64
	burst         float64 // mean burst length in records; ≤ 1 is independent loss
}

func (config testDataLinkConfig) active() bool {
	return config.bitsPerSecond > 0 || config.delay > 0 || config.lossIn > 0 || config.lossOut > 0
}

func testDataLinkFromEnvironment(getenv func(string) string) testDataLinkConfig {
	config := testDataLinkConfig{
		bitsPerSecond: parseTestDataLinkKbps(getenv("RDEV_TEST_DATA_LINK_KBPS")) * 1000,
		delay:         time.Duration(parseTestDataLinkKbps(getenv("RDEV_TEST_DATA_LINK_RTT_MS"))) * time.Millisecond,
		lossIn:        parseTestDataLinkPercent(getenv("RDEV_TEST_DATA_LINK_LOSS_IN")),
		lossOut:       parseTestDataLinkPercent(getenv("RDEV_TEST_DATA_LINK_LOSS_OUT")),
		seed:          1,
		burst:         parseTestDataLinkBurst(getenv("RDEV_TEST_DATA_LINK_BURST")),
	}
	if seed, err := strconv.ParseInt(strings.TrimSpace(getenv("RDEV_TEST_DATA_LINK_SEED")), 10, 64); err == nil {
		config.seed = seed
	}
	return config
}

// parseTestDataLinkKbps reads a positive whole number; anything else is off (0).
func parseTestDataLinkKbps(raw string) int {
	n, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil || n <= 0 {
		return 0
	}
	return n
}

// parseTestDataLinkPercent reads a percentage in (0, 100] as a probability; anything else is no loss.
func parseTestDataLinkPercent(raw string) float64 {
	percent, err := strconv.ParseFloat(strings.TrimSpace(raw), 64)
	if err != nil || percent <= 0 || percent > 100 {
		return 0
	}
	return percent / 100
}

// parseTestDataLinkBurst reads a mean burst length above 1; anything else is independent loss (0).
func parseTestDataLinkBurst(raw string) float64 {
	length, err := strconv.ParseFloat(strings.TrimSpace(raw), 64)
	if err != nil || length <= 1 {
		return 0
	}
	return length
}

// isDTLSRecord: RFC 7983's demultiplexing — a first byte in 20..63 is DTLS.
func isDTLSRecord(packet []byte) bool { return len(packet) > 0 && packet[0] >= 20 && packet[0] <= 63 }

// isDTLSApplicationData: a record of content type 23 — what SCTP rides in.
func isDTLSApplicationData(packet []byte) bool { return len(packet) > 0 && packet[0] == 23 }

type dataLinkPacket struct {
	payload     []byte
	destination net.Addr
	arrives     time.Time
}

// dataLinkDirection counts one direction's application-data records, and those the link dropped.
type dataLinkDirection struct{ records, dropped uint64 }

// testDataLink is the link: a loss on each side, then on the way out the bottleneck (one goroutine sends the queued
// records at `bitsPerSecond`) and the delay (another writes each record once it has arrived).
type testDataLink struct {
	net.PacketConn
	config        testDataLinkConfig
	maxQueueBytes int

	mu         sync.Mutex
	random     *rand.Rand
	queue      []dataLinkPacket // waiting for the bottleneck
	queueBytes int
	inFlight   []dataLinkPacket // through the bottleneck, crossing the delay — in arrival order
	in, out    dataLinkDirection
	bad        [2]bool // the Gilbert–Elliott state per direction: 0 in, 1 out
	wake       chan struct{}
	wakeFlight chan struct{}
	done       chan struct{}
	closeOnce  sync.Once
}

func newTestDataLink(connection net.PacketConn, config testDataLinkConfig) *testDataLink {
	maxQueue := config.bitsPerSecond / 8
	if maxQueue < 16*1024 {
		maxQueue = 16 * 1024
	}
	link := &testDataLink{
		PacketConn: connection, config: config, maxQueueBytes: maxQueue,
		random: rand.New(rand.NewSource(config.seed)),
		wake:   make(chan struct{}, 1), wakeFlight: make(chan struct{}, 1), done: make(chan struct{}),
	}
	if config.bitsPerSecond > 0 {
		go link.serialize()
	}
	if config.delay > 0 {
		go link.propagate()
	}
	if config.lossIn > 0 || config.lossOut > 0 {
		go link.report()
	}
	return link
}

// lose decides one record's fate and counts it. `side` is 0 for the way in, 1 for the way out.
func (link *testDataLink) lose(probability float64, direction *dataLinkDirection, side int) bool {
	link.mu.Lock()
	defer link.mu.Unlock()
	direction.records++
	lost := false
	switch {
	case probability <= 0:
	case probability >= 1:
		lost = true
	case link.config.burst <= 1:
		lost = link.random.Float64() < probability
	default:
		if link.bad[side] {
			if link.random.Float64() < 1/link.config.burst {
				link.bad[side] = false
			}
		} else if link.random.Float64() < probability/(link.config.burst*(1-probability)) {
			link.bad[side] = true
		}
		lost = link.bad[side]
	}
	if lost {
		direction.dropped++
	}
	return lost
}

// ReadFrom is the way IN: a client's record the link loses never reaches pion.
func (link *testDataLink) ReadFrom(payload []byte) (int, net.Addr, error) {
	for {
		n, source, err := link.PacketConn.ReadFrom(payload)
		if err != nil || !isDTLSApplicationData(payload[:n]) || !link.lose(link.config.lossIn, &link.in, 0) {
			return n, source, err
		}
	}
}

// WriteTo is the way OUT.
func (link *testDataLink) WriteTo(payload []byte, destination net.Addr) (int, error) {
	if !isDTLSRecord(payload) {
		return link.PacketConn.WriteTo(payload, destination)
	}
	if isDTLSApplicationData(payload) && link.lose(link.config.lossOut, &link.out, 1) {
		return len(payload), nil
	}
	if link.config.bitsPerSecond == 0 && link.config.delay == 0 {
		return link.PacketConn.WriteTo(payload, destination)
	}
	packet := dataLinkPacket{payload: append([]byte(nil), payload...), destination: destination}
	if link.config.bitsPerSecond == 0 {
		link.depart(packet)
		return len(payload), nil
	}
	link.mu.Lock()
	if link.queueBytes+len(payload) > link.maxQueueBytes {
		link.mu.Unlock()
		return len(payload), nil // tail drop: the bottleneck's buffer is full
	}
	link.queue = append(link.queue, packet)
	link.queueBytes += len(payload)
	link.mu.Unlock()
	signal(link.wake)
	return len(payload), nil
}

// depart puts a record on the wire beyond the bottleneck: at once, or after the delay.
func (link *testDataLink) depart(packet dataLinkPacket) {
	if link.config.delay == 0 {
		_, _ = link.PacketConn.WriteTo(packet.payload, packet.destination)
		return
	}
	link.mu.Lock()
	packet.arrives = time.Now().Add(link.config.delay) // taken under the lock: arrivals stay in order
	link.inFlight = append(link.inFlight, packet)
	link.mu.Unlock()
	signal(link.wakeFlight)
}

func signal(wake chan struct{}) {
	select {
	case wake <- struct{}{}:
	default:
	}
}

// serialize is the bottleneck: each record occupies the link for its own length at the link's rate.
func (link *testDataLink) serialize() {
	next := time.Now()
	for {
		link.mu.Lock()
		if len(link.queue) == 0 {
			link.mu.Unlock()
			select {
			case <-link.wake:
				continue
			case <-link.done:
				return
			}
		}
		packet := link.queue[0]
		link.queue = link.queue[1:]
		link.queueBytes -= len(packet.payload)
		link.mu.Unlock()
		if now := time.Now(); next.Before(now) {
			next = now
		}
		next = next.Add(time.Duration(len(packet.payload)*8) * time.Second / time.Duration(link.config.bitsPerSecond))
		select {
		case <-time.After(time.Until(next)):
		case <-link.done:
			return
		}
		link.depart(packet)
	}
}

// propagate writes each record once its delay is over.
func (link *testDataLink) propagate() {
	for {
		link.mu.Lock()
		if len(link.inFlight) == 0 {
			link.mu.Unlock()
			select {
			case <-link.wakeFlight:
				continue
			case <-link.done:
				return
			}
		}
		packet := link.inFlight[0]
		link.mu.Unlock()
		select {
		case <-time.After(time.Until(packet.arrives)):
		case <-link.done:
			return
		}
		link.mu.Lock()
		link.inFlight = link.inFlight[1:]
		link.mu.Unlock()
		_, _ = link.PacketConn.WriteTo(packet.payload, packet.destination)
	}
}

// report prints what the loss did, every 2 s while records cross — so a run shows the rate it actually got (a killed
// host's last line is at most 2 s old).
func (link *testDataLink) report() {
	var seen uint64
	for {
		select {
		case <-time.After(2 * time.Second):
		case <-link.done:
			return
		}
		link.mu.Lock()
		in, out := link.in, link.out
		link.mu.Unlock()
		if in.records+out.records == seen {
			continue
		}
		seen = in.records + out.records
		fmt.Printf("[test-link] in %d records, %d dropped (%.1f%%) · out %d records, %d dropped (%.1f%%)\n",
			in.records, in.dropped, percentOf(in), out.records, out.dropped, percentOf(out))
	}
}

func percentOf(direction dataLinkDirection) float64 {
	if direction.records == 0 {
		return 0
	}
	return 100 * float64(direction.dropped) / float64(direction.records)
}

func (link *testDataLink) Close() error {
	link.closeOnce.Do(func() { close(link.done) })
	return link.PacketConn.Close()
}
