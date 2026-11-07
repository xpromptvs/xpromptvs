package main

import (
	"net"
	"sync/atomic"
	"testing"
	"time"

	"github.com/pion/webrtc/v4"
)

// outageConn drops every datagram, both ways, while `down` is set — a network that is simply gone,
// with both ends still running their timers.
type outageConn struct {
	net.PacketConn
	down *atomic.Bool
}

func (c *outageConn) ReadFrom(p []byte) (int, net.Addr, error) {
	for {
		n, addr, err := c.PacketConn.ReadFrom(p)
		if err != nil || !c.down.Load() {
			return n, addr, err
		}
	}
}

func (c *outageConn) WriteTo(p []byte, addr net.Addr) (int, error) {
	if c.down.Load() {
		return len(p), nil
	}
	return c.PacketConn.WriteTo(p, addr)
}

// A MESSAGE SENT INTO AN OUTAGE ARRIVES SOON AFTER THE NETWORK RETURNS — within sctpRTOMax, not after
// SCTP's exponential backoff has run out to pion's default 60 s ceiling (docs/engine.md, "SCTP's
// backoff is capped"). The terminal stream rides this association: after a phone's network dropped
// for a few seconds and came back by an ICE restart (which keeps the association), its terminal sat
// silent until the next retransmission. Measured shape, from pion/sctp's own schedule (RTO.min 1 s,
// doubling): a message sent as an 8 s outage begins is retransmitted at +1, +3, +7, +15 s uncapped —
// ~7 s after the network returns — and at +1, +3, +6, +9 s with a 3 s cap — ~1 s after.
func TestAMessageSentIntoAnOutageArrivesSoonAfterIt(t *testing.T) {
	var down atomic.Bool
	hostPacketConnForTests = func(c net.PacketConn) net.PacketConn { return &outageConn{PacketConn: c, down: &down} }
	t.Cleanup(func() { hostPacketConnForTests = nil })

	pair := newTestOfferPair(t)
	if err := pair.session.SetAnswer(pair.answer); err != nil {
		t.Fatalf("SetAnswer: %v", err)
	}
	terminal := pair.awaitRemoteChannel(t, rdevTerminalChannelLabel)
	received := make(chan string, 8)
	terminal.OnMessage(func(message webrtc.DataChannelMessage) { received <- string(message.Data) })
	await := func(want string, within time.Duration) time.Duration {
		t.Helper()
		start := time.Now()
		for {
			select {
			case got := <-received:
				if got == want {
					return time.Since(start)
				}
			case <-time.After(within - time.Since(start)):
				t.Fatalf("%q never arrived within %v", want, within)
			}
		}
	}

	// A round trip first: the association has an RTT sample, so its RTO is at RTO.min.
	if err := waitSendChannelData(pair.session, rdevTerminalChannelLabel, []byte("before")); err != nil {
		t.Fatalf("send before the outage: %v", err)
	}
	await("before", 10*time.Second)

	const outage = 8 * time.Second
	down.Store(true)
	if err := pair.session.SendChannelData(rdevTerminalChannelLabel, []byte("during")); err != nil {
		t.Fatalf("send into the outage: %v", err)
	}
	time.Sleep(outage)
	down.Store(false)
	took := await("during", 30*time.Second)
	if took > sctpRTOMax+500*time.Millisecond {
		t.Fatalf("a message sent into an %v outage arrived %v after the network returned; SCTP's "+
			"backoff must be capped at %v", outage, took.Round(100*time.Millisecond), sctpRTOMax)
	}
	t.Logf("arrived %v after the network returned", took.Round(10*time.Millisecond))
}
