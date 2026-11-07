package main

import (
	"fmt"
	"net"
	"sync/atomic"
	"testing"
	"time"
)

// laneBlackoutConn drops every DTLS application-data record — the SCTP every data channel rides — both ways while
// `down` is set, and counts what it dropped. STUN and the DTLS handshake pass, so ICE stays connected: the outage spec
// §4 describes, "connected" with nothing crossing.
type laneBlackoutConn struct {
	net.PacketConn
	down    *atomic.Bool
	dropped *atomic.Int64
}

func (c *laneBlackoutConn) ReadFrom(p []byte) (int, net.Addr, error) {
	for {
		n, addr, err := c.PacketConn.ReadFrom(p)
		if err != nil || !c.down.Load() || !isDTLSApplicationData(p[:n]) {
			return n, addr, err
		}
		c.dropped.Add(1)
	}
}

func (c *laneBlackoutConn) WriteTo(p []byte, addr net.Addr) (int, error) {
	if c.down.Load() && isDTLSApplicationData(p) {
		c.dropped.Add(1)
		return len(p), nil
	}
	return c.PacketConn.WriteTo(p, addr)
}

// ACROSS A BLACKOUT PION HOLDS AT MOST ONE QUEUE TARGET FOR THE LANE, AND THE LANE IS ACKNOWLEDGED SOON AFTER THE PATH
// RETURNS (docs/superpowers/specs/2026-10-12-terminal-lane-design.md §1, "The carrier"). The lane is reliable, so
// everything pion holds when the path goes is retransmitted when it returns, stale or not: room = queueTarget −
// BufferedAmount (rdevLane.flush) is what keeps that to the target, never the burst a terminal printed meanwhile —
// the rest waits in the lane's own queue. This is the one end-to-end check that the gate reads pion's REAL buffered
// amount. A steady terminal stream (2 KB every 20 ms, 100 KB/s) runs into a 2 s blackout of every application-data
// record both ways; pion's buffered amount for the lane is read after every send — 16 384 B, the target, in every
// run measured. Mutation: without the gate (room unbounded) pion holds the whole stream, past the target within
// 100 ms.
//
// HOW SOON AFTER THE RETURN IS SCTP's, NOT THE LANE's: the lane has no room until pion's bytes are acknowledged, and
// nothing crosses until a timer on one end fires — a tail-loss probe still re-arming (ms), or else T3, whose backoff
// is capped at sctpRTOMax, plus the receiver's delayed SACK: 2 ms to 1.2 s measured over 40 runs of this 2 s blackout.
// So the bound is TestAMessageSentIntoAnOutageArrivesSoonAfterIt's.
func TestALaneHoldsAtMostItsQueueTargetInPionAcrossABlackout(t *testing.T) {
	const blackout = 2 * time.Second
	var down atomic.Bool
	var dropped atomic.Int64
	hostPacketConnForTests = func(c net.PacketConn) net.PacketConn {
		return &laneBlackoutConn{PacketConn: c, down: &down, dropped: &dropped}
	}
	t.Cleanup(func() { hostPacketConnForTests = nil })

	pair := lanePair(t)
	if err := pair.session.SetAnswer(pair.answer); err != nil {
		t.Fatalf("SetAnswer: %v", err)
	}
	remote := newTestLanePeer(pair.awaitRemoteChannel(t, laneChannelLabel))
	defer remote.close()
	remote.awaitOpen(t)
	awaitChannelsOpen(t, pair, "terminal", "input", "control", "bulk")
	// The answerer's deliveries are drained: its channel holds 64, and blocked, its onMessage — and so its feedback —
	// would stop.
	stopDraining := make(chan struct{})
	defer close(stopDraining)
	go func() {
		for {
			select {
			case <-remote.got:
			case <-stopDraining:
				return
			}
		}
	}()
	pair.session.mutex.Lock()
	lane := pair.session.lane
	pair.session.mutex.Unlock()
	// await polls a condition on the lane's engine (under its lock) and says how long it took — failing with `what`
	// once it has not held within `within`, however soon after that it would have.
	await := func(what string, within time.Duration, done func(e *laneEngine) bool) time.Duration {
		t.Helper()
		start := time.Now()
		for {
			lane.mu.Lock()
			ok := done(lane.engine)
			lane.mu.Unlock()
			took := time.Since(start)
			if ok && took <= within {
				return took
			}
			if took > within {
				t.Fatalf("%s: not within %v", what, within)
			}
			time.Sleep(time.Millisecond)
		}
	}
	read := func() (buffered, target int) {
		lane.mu.Lock()
		target = lane.engine.queueTarget(lane.now())
		lane.mu.Unlock()
		return int(lane.channel.BufferedAmount()), target
	}

	// One message across first, acknowledged: the lane is live, and the last second's acknowledgements are next to
	// nothing, so the target the blackout meets is its 16 KB floor whatever the base round trip reads.
	if err := pair.session.SendChannelData(rdevControlChannelLabel, []byte(`{"t":"hello"}`)); err != nil {
		t.Fatal(err)
	}
	await("the first message acknowledged", 5*time.Second, func(e *laneEngine) bool { return e.nextESI == e.heldFrom })

	frame := make([]byte, 2000)
	tick := time.NewTicker(20 * time.Millisecond)
	defer tick.Stop()
	down.Store(true)
	start := time.Now()
	worst, worstTarget, peakTarget, sends := 0, 0, 0, 0
	for time.Since(start) < blackout {
		if err := pair.session.SendChannelData(rdevTerminalChannelLabel, frame); err != nil {
			t.Fatalf("send into the blackout: %v", err)
		}
		sends++
		buffered, target := read()
		peakTarget = max(peakTarget, target)
		if buffered > worst {
			worst, worstTarget = buffered, target
		}
		if buffered > peakTarget+lanePacketMax {
			t.Fatalf("%v into the blackout pion held %d B for the lane, past its queue target %d B (+ one packet): "+
				"the lane must hand pion only room = target − buffered — everything pion holds is retransmitted, "+
				"stale, when the path returns", time.Since(start).Round(time.Millisecond), buffered, peakTarget)
		}
		<-tick.C
	}
	lane.mu.Lock()
	mark := lane.engine.nextESI
	waiting := lane.engine.buffered(0)
	lane.mu.Unlock()
	down.Store(false)
	// Guards: the blackout cut something, the stream outran the target (the lane had more than room to hold back), and
	// pion was filled to it — so the bound above was the binding limit, not an idle lane.
	if dropped.Load() == 0 {
		t.Fatal("the blackout dropped nothing")
	}
	if waiting < 4*peakTarget {
		t.Fatalf("only %d B of the stream waited unacknowledged at the blackout's end (target %d B): the gate held "+
			"nothing back", waiting, peakTarget)
	}
	if worst < laneQueueTarget/2 {
		t.Fatalf("pion held at most %d B during the blackout: the lane never reached its target, so nothing was bounded",
			worst)
	}
	took := await(fmt.Sprintf("the lane acknowledged what it sent before the path returned — pion retransmits its "+
		"one queue target on SCTP's next timer (a tail-loss probe, or T3 under its %v backoff cap, plus a delayed "+
		"SACK), so later means the backlog was more than the target or the backoff is no longer capped", sctpRTOMax),
		sctpRTOMax+500*time.Millisecond, func(e *laneEngine) bool { return e.heldFrom >= mark })
	buffered, _ := read()
	t.Logf("blackout %v: %d sends, %d records dropped, pion max %d B (target then %d, peak %d), %d B waiting; "+
		"acknowledged %v after the return (pion now %d B)", blackout, sends, dropped.Load(), worst, worstTarget,
		peakTarget, waiting, took.Round(time.Millisecond), buffered)
}
