package main

import (
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/webrtc/v4"
)

// THE LANE'S SESSION GLUE (docs/superpowers/specs/2026-10-12-terminal-lane-design.md §1, §4): one data channel —
// `lane`, unordered and reliable (session.go says why) — carrying terminal, input and control as the streams of one
// laneEngine, whose own repair usually rebuilds a lost packet before SCTP's retransmission arrives: a copy whose symbol
// the decoder already has, and which measures nothing (laneEngine.receive).
// Swift never sees it: pion_peer_send_data(0…2) and pion_peer_channel_buffered(0…2) reach the streams, and each
// stream's open and messages are published under its channel's label (session.go).
//
// LOCK ORDER: lane.mu guards the engine, the timer and the lane's state, and is never held across a call OUT — not
// `deliver`, not `opened` (both reach Swift), not pion's Send or Close. Two reads of pion's are made under it, both
// safe: BufferedAmount (pion runs the low-water callback on its own goroutine, after releasing the stream's lock) and
// `connected` (the peer connection's state, an atomic load). The session never holds its own mutex while calling in
// here.
//
// ONE SENDER (`run`): a single goroutine per lane polls the engine and hands pion its packets, so they reach pion in
// the order the engine numbered them (`pkt`), and the room each poll gets is measured with every earlier packet
// already in pion's queue. Everything else — pion's read goroutine (onMessage), Swift's threads (send), the timer and
// OnBufferedAmountLow — only signals it (kick). When any of them flushed by itself, two flushes interleaved: pkt N+1
// reached the wire before N, and the receiver, which records only the newest pkt, counted N lost for its whole
// 256-packet window — a loss estimate inflated by the Mac's own reordering, driving proactive repair; and each read the
// room before the others' packets landed, so together they could hand pion a multiple of the queue target. pion's own
// paths never wait on the sender: OnBufferedAmountLow runs in a goroutine pion starts for it (webrtc/v4 v4.2.15,
// DataChannel.makeBufferedAmountLowHandler) after the association dropped its lock (sctp v1.10.0, handleSack →
// Stream.onBufferReleased, which drops the stream's lock before calling it); Send (WriteDataChannel → Stream.WriteSCTP
// → Association.sendPayloadData) takes the association's lock only to queue the chunks — block-write is never enabled
// here — and calls nothing back.

// OnBufferedAmountLow refills pion's queue for the lane from here up to the engine's queueTarget.
const laneQueueLow = 4 * 1024

// laneRepollMs is the longest flush waits for room once pion's queue has none left for a packet (laneFlushWake).
const laneRepollMs = 5

// laneStreamLabels is rdevChannelLabels[:3], in order — the ABI's slots 0–2 (TestTheLaneStreamsAreTheABIsFirstThreeChannels).
var laneStreamLabels = [laneStreams]string{rdevTerminalChannelLabel, rdevInputChannelLabel, rdevControlChannelLabel}

// laneCarrier is what the lane needs of its data channel once wired: a *webrtc.DataChannel, or a test's double.
type laneCarrier interface {
	Send(data []byte) error
	BufferedAmount() uint64
	Close() error
}

func laneStreamIndex(label string) (int, bool) {
	for stream, l := range laneStreamLabels {
		if l == label {
			return stream, true
		}
	}
	return 0, false
}

type rdevLane struct {
	mu      sync.Mutex
	engine  *laneEngine
	channel laneCarrier
	start   time.Time
	timer   *time.Timer
	open    bool
	closed  bool // halt ran (close, pion's OnClose or a stuck lane): nothing reopens the lane or re-arms the timer
	started bool // the sender runs (from the lane's open); close waits for it only then
	// linkUp: connectedAgain has run since flush last read the link down. A stuck lane closes only while it is set
	// (flush): pion STORES a new connection state before it runs the handler that reaches connectedAgain, so
	// `connected` alone reads true across a reconnect while the stuck clocks still hold the outage.
	linkUp    bool
	stuckSaid bool
	// downSeen: the link read disconnected or failed since it last connected (linkLost). reconnectedAt: when it
	// connected AGAIN after that (−1: never) — from then on a lane whose oldest unacknowledged symbol sees no progress
	// for laneStalledAfterReconnectMs closes, and the page rebuilds (flush).
	downSeen      bool
	reconnectedAt int64
	connected     func() bool
	opened        func(label string)
	deliver       func(label string, data []byte)
	announce      sync.Once // the three streams' opens, published once (becomeOpen)
	// The sender's signals: `wake` holds at most one pending flush (kick), `quit` closes once (halt), and the sender
	// closes `done` as it exits.
	wake     chan struct{}
	quit     chan struct{}
	quitOnce sync.Once
	done     chan struct{}
	// What crossed pion, for the summary line (laneStatsEvery): packets and bytes in each direction, and the sends pion
	// refused. Atomic: onMessage counts on pion's goroutine, flush on the sender's.
	rxPkts, rxBytes, txPkts, txBytes, txRefused atomic.Uint64
}

// laneStalledAfterReconnectMs: once the link has dropped and come back, a lane whose oldest unacknowledged symbol sees no
// progress for this long closes — the page rebuilds, on a fresh SCTP association. After a network blink a browser's
// SCTP may hold everything the page sends behind its retransmission backoff (a phone over TURN, 2026-10-13: its
// keystrokes reached the Mac ~25 s late, srtt 24.8 s), which no amount of the lane's own repair gets past: its repairs
// queue behind the same backoff. 30 s (the engine's stuck) stays the threshold for a link that never dropped — a slow
// link or a throttled background page is not a broken one.
const laneStalledAfterReconnectMs = 5000

// laneStatsEvery is how often a lane that is open prints its summary line ([lane] …): what crossed pion each way, what
// the engine holds and has acknowledged, what it decoded, the peer's last word and the round trip. A lane that stalls
// on a path no measurement covered (a phone over TURN, 2026-10-13: keystrokes echoed and no reply, a control message
// a minute late) leaves its state in the host's log instead of nothing — the stuck and violation lines were the only
// two the lane ever printed. Packaged-app output goes nowhere unless the app runs under a log wrapper (docs/gotchas.md).
const laneStatsEvery = 5 * time.Second

func newRdevLane(channel *webrtc.DataChannel, seed uint32, connected func() bool, opened func(label string),
	deliver func(label string, data []byte)) *rdevLane {
	lane := newRdevLaneOver(channel, seed, connected, opened, deliver)
	channel.SetBufferedAmountLowThreshold(laneQueueLow)
	channel.OnBufferedAmountLow(lane.kick)
	channel.OnOpen(lane.onOpen)
	channel.OnClose(lane.onClose)
	channel.OnMessage(lane.onMessage)
	return lane
}

// newRdevLaneOver is the lane over any carrier, its pion callbacks left to the caller (newRdevLane, or a test that
// calls onOpen, onMessage and kick itself).
func newRdevLaneOver(channel laneCarrier, seed uint32, connected func() bool, opened func(label string),
	deliver func(label string, data []byte)) *rdevLane {
	return &rdevLane{engine: newLaneEngine(seed, 0), channel: channel, start: time.Now(), connected: connected,
		opened: opened, deliver: deliver, wake: make(chan struct{}, 1), quit: make(chan struct{}),
		done: make(chan struct{}), reconnectedAt: -1}
}

// onOpen is pion's OnOpen — for a channel this end dials, the peer's DATA_CHANNEL_ACK.
func (lane *rdevLane) onOpen() {
	lane.becomeOpen()
	lane.kick()
}

// onClose is pion's OnClose: the sender is told to stop, not waited for — this is pion's goroutine.
func (lane *rdevLane) onClose() {
	lane.halt()
}

// onMessage: pion calls it sequentially for one channel, so deliveries leave in the order they were decoded. Each
// delivery is the engine's own copy: nothing handed on aliases pion's reused read buffer.
func (lane *rdevLane) onMessage(message webrtc.DataChannelMessage) {
	lane.becomeOpen() // before lane.mu: Do may wait for the other path's opens to be published
	lane.rxPkts.Add(1)
	lane.rxBytes.Add(uint64(len(message.Data)))
	lane.mu.Lock()
	lane.engine.receive(message.Data, lane.now())
	delivered := lane.engine.takeDelivered()
	lane.mu.Unlock()
	for _, d := range delivered {
		lane.deliver(laneStreamLabels[d.stream], d.data)
	}
	lane.kick()
}

// becomeOpen opens the lane and publishes its three streams' opens — ONCE, at pion's OnOpen or at the first message,
// whichever comes first. THE FIRST MESSAGE IS THE IMPLICIT ACK, as libwebrtc treats it: this end dials the lane, so
// pion's OnOpen waits for the peer's DATA_CHANNEL_ACK, while pion's read loop already runs from the channel's open and
// reads unordered chunks before ordered ones. On a lossy link a lost ACK would let the page's first messages reach
// Swift an SCTP retransmission timeout before the opens — on streams it had not heard open, its replies refused by
// send, and the lane's feedback held back by flush. pion reads the channel Open before the ACK (handleOpen), so sends
// work from here; until the ACK, pion sends them ordered and reliable (RFC 8832; pion/datachannel's
// commitReliabilityParams).
//
// sync.Once also ORDERS the two paths: a message arriving while OnOpen is still publishing waits in Do until the
// opens are out, so no delivery overtakes them. Do runs Swift's callbacks holding only the Once's own lock, which
// nothing but these two pion paths takes. The sender starts here: a lane that never opens never had one.
func (lane *rdevLane) becomeOpen() {
	lane.announce.Do(func() {
		lane.mu.Lock()
		if lane.closed {
			lane.mu.Unlock()
			return
		}
		lane.open, lane.started = true, true
		lane.mu.Unlock()
		go lane.run()
		for _, label := range laneStreamLabels {
			lane.opened(label)
		}
	})
}

func (lane *rdevLane) now() int64 { return int64(time.Since(lane.start) / time.Millisecond) }

func (lane *rdevLane) send(stream int, data []byte) error {
	lane.mu.Lock()
	if !lane.open {
		lane.mu.Unlock()
		return fmt.Errorf("%w: the lane is not open", errSession)
	}
	err := lane.engine.send(stream, data)
	lane.mu.Unlock()
	if err != nil {
		return err
	}
	lane.kick()
	return nil
}

func (lane *rdevLane) buffered(stream int) (uint64, bool) {
	lane.mu.Lock()
	defer lane.mu.Unlock()
	return uint64(lane.engine.buffered(stream)), lane.open
}

// connectedAgain: the peer connection reached `connected` — the stuck clocks start over (an outage is not a stuck
// lane; spec §4), and only then may a stuck lane close again (linkUp). Every lane gets one for its first connection:
// it is created before its peer connection's first offer, so that connection's `connected` reaches handlePeerState
// with session.lane already set.
func (lane *rdevLane) connectedAgain() {
	lane.mu.Lock()
	now := lane.now()
	lane.engine.resetStuck(now)
	lane.linkUp = true
	if lane.downSeen {
		lane.downSeen = false
		lane.reconnectedAt = now
	}
	lane.mu.Unlock()
	lane.kick()
}

// linkLost: the peer connection read disconnected or failed — its next `connected` is a RECONNECT
// (laneStalledAfterReconnectMs).
func (lane *rdevLane) linkLost() {
	lane.mu.Lock()
	lane.downSeen = true
	lane.mu.Unlock()
}

// stalledAfterReconnect: the link dropped and came back, and the oldest unacknowledged symbol has seen no progress
// since for laneStalledAfterReconnectMs. Under lane.mu.
func (lane *rdevLane) stalledAfterReconnect(now int64) bool {
	return lane.reconnectedAt >= 0 && lane.engine.stalledFor(now) >= laneStalledAfterReconnectMs
}

// halt marks the lane closed, stops its timer and tells the sender to exit, waiting for nothing — callable from the
// sender itself and from pion's goroutines. It says whether a sender was started (and so will close `done`).
func (lane *rdevLane) halt() bool {
	lane.mu.Lock()
	lane.closed, lane.open = true, false
	lane.stopTimerLocked()
	started := lane.started
	lane.mu.Unlock()
	lane.quitOnce.Do(func() { close(lane.quit) })
	return started
}

// stop halts the lane and waits for its sender to exit: nothing of the lane runs after it returns. Never from the
// sender itself.
func (lane *rdevLane) stop() {
	if lane.halt() {
		<-lane.done
	}
}

// close stops the lane before closing its channel, so no timer or sender outlives the session even should pion never
// call OnClose after the peer connection goes.
func (lane *rdevLane) close() error {
	lane.stop()
	return lane.channel.Close()
}

// kick asks the sender for a flush: at most one waits, so a kick while one is pending costs nothing.
func (lane *rdevLane) kick() {
	select {
	case lane.wake <- struct{}{}:
	default:
	}
}

// run is the lane's one sender: every flush happens here, in turn, until the lane halts or closes itself.
func (lane *rdevLane) run() {
	defer close(lane.done)
	stats := time.NewTicker(laneStatsEvery)
	defer stats.Stop()
	for {
		select {
		case <-lane.quit:
			return
		case <-stats.C:
			fmt.Println(lane.summary())
			continue
		case <-lane.wake:
		}
		if lane.flush() {
			return
		}
	}
}

// summary is the lane's state in one line, read under its lock: what crossed pion since it opened (tx/rx packets and
// KiB, sends pion refused), pion's queue against the engine's target, the SENDING side (symbols handed out, the first
// not yet acknowledged, held, repairs owed, the peer's last feedback and loss report, the round trip and its base) and
// the RECEIVING side (the first symbol not yet known, the highest seen, the last packet's age, an unfilled hole's age).
// Ages are ms, −1 for never.
func (lane *rdevLane) summary() string {
	lane.mu.Lock()
	defer lane.mu.Unlock()
	now := lane.now()
	e := lane.engine
	age := func(at int64, ever bool) int64 {
		if !ever {
			return -1
		}
		return now - at
	}
	return fmt.Sprintf("[lane] tx %d pkts %d KiB refused %d · rx %d pkts %d KiB · queue %d/%d B · out next=%d acked<%d held=%d urgent=%d owed=%d fb-age=%d loss=%d‰ srtt=%.0f base=%.0f · in cum=%d high=%d pkt-age=%d hole-age=%d%s",
		lane.txPkts.Load(), lane.txBytes.Load()/1024, lane.txRefused.Load(), lane.rxPkts.Load(), lane.rxBytes.Load()/1024,
		lane.channel.BufferedAmount(), e.queueTarget(now),
		e.nextESI, e.heldFrom, len(e.held), len(e.urgent), e.proactiveOwed, age(e.lastFeedbackAt, e.everFeedback),
		e.lossPermille, e.srtt, e.baseRTT,
		e.cumESI, e.highestESI, age(e.lastAt, e.everPkt), age(e.holeSince, e.holeSince >= 0),
		map[bool]string{true: " VIOLATED", false: ""}[e.violated])
}

func (lane *rdevLane) stopTimerLocked() {
	if lane.timer != nil {
		lane.timer.Stop()
		lane.timer = nil
	}
}

// flush is the sender's one step (run): it sends what the engine has now — never more than pion's queue for the lane
// may take, measured now, with every packet this goroutine handed pion before already counted — in the engine's order,
// and arms the timer for its next wake. The packets go out after the lock is released, still from this goroutine. A
// lane stuck on a connected link is closed here (halt, never stop: that would wait for this goroutine), and flush says
// so.
func (lane *rdevLane) flush() bool {
	lane.mu.Lock()
	if !lane.open {
		lane.mu.Unlock()
		return false
	}
	now := lane.now()
	// Read under the lock, so a `false` here cannot clear a linkUp that connectedAgain set for a later connection:
	// that connection's state is stored before its handler runs, so its connectedAgain has not run if this reads
	// false, and will set linkUp after this flush lets go.
	connected := lane.connected()
	if !connected {
		lane.linkUp = false
	}
	room := lane.engine.queueTarget(now) - int(lane.channel.BufferedAmount())
	packets := lane.engine.poll(now, room)
	for _, packet := range packets {
		room -= len(packet)
	}
	stalled := lane.stalledAfterReconnect(now)
	closing := (lane.engine.stuck(now) || stalled) && connected && lane.linkUp
	violated := lane.engine.violated
	say := closing && !lane.stuckSaid
	lane.stuckSaid = lane.stuckSaid || closing
	lane.stopTimerLocked()
	if wake := laneFlushWake(now, lane.engine.nextWake(now), room); wake >= 0 && !closing {
		lane.timer = time.AfterFunc(time.Duration(wake-now)*time.Millisecond, lane.kick)
	}
	lane.mu.Unlock()
	for _, packet := range packets {
		if err := lane.channel.Send(packet); err != nil {
			lane.txRefused.Add(1)
			continue
		}
		lane.txPkts.Add(1)
		lane.txBytes.Add(uint64(len(packet)))
	}
	if closing {
		if say && violated {
			fmt.Printf("[lane] the page broke the lane's protocol; closing the lane\n")
		} else if say && stalled {
			fmt.Printf("[lane] no progress for %d s after the link came back; closing the lane\n", laneStalledAfterReconnectMs/1000)
		} else if say {
			fmt.Printf("[lane] no progress for %d s on a connected link; closing the lane\n", laneStuckMs/1000)
		}
		lane.halt()
		_ = lane.channel.Close() // the page hears the lane close and rebuilds (spec §4)
	}
	return closing
}

// laneFlushWake is when flush runs next: the engine's own wake (−1: none), brought forward to at most laneRepollMs
// away when this flush left pion's queue with less room than one packet (`roomLeft`: queueTarget − BufferedAmount −
// the bytes just sent; feedback ignores room, so it can be negative). OnBufferedAmountLow alone would wait too long
// there: it fires only when pion's count drops below laneQueueLow, and pion counts bytes until SCTP ACKNOWLEDGES
// them, so it can come a round trip after the room did. And what the queue refused is not always in nextWake: an
// urgent (gap or timer) repair too big for the room stays queued in the engine, which nextWake does not look at.
func laneFlushWake(now, engineWake int64, roomLeft int) int64 {
	if roomLeft >= lanePacketMax {
		return engineWake
	}
	if soon := now + laneRepollMs; engineWake < 0 || engineWake > soon {
		return soon
	}
	return engineWake
}
