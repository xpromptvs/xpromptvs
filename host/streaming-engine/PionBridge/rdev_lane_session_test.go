package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"net"
	"reflect"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/pion/webrtc/v4"
)

// THE LANE THROUGH A REAL SESSION (docs/superpowers/specs/2026-10-12-terminal-lane-design.md §1, §4): the offer path
// creates `lane` and `bulk` and none of the old three; terminal, input and control open together when the lane does;
// a message crosses either way intact; the streams' buffered amounts are the lane's.

// testLanePeer is the answerer's end of the lane — the same engine, flushed by a ticker as the page's timers would.
type testLanePeer struct {
	mu      sync.Mutex
	engine  *laneEngine
	channel *webrtc.DataChannel
	start   time.Time
	got     chan laneDelivery
	stop    chan struct{}
}

func newTestLanePeer(channel *webrtc.DataChannel) *testLanePeer {
	p := &testLanePeer{engine: newLaneEngine(77, 0), channel: channel, start: time.Now(),
		got: make(chan laneDelivery, 64), stop: make(chan struct{})}
	channel.OnMessage(func(m webrtc.DataChannelMessage) {
		p.mu.Lock()
		p.engine.receive(m.Data, p.now())
		delivered := p.engine.takeDelivered()
		p.mu.Unlock()
		for _, d := range delivered {
			p.got <- d
		}
		p.flush()
	})
	go func() {
		ticker := time.NewTicker(5 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				p.flush()
			case <-p.stop:
				return
			}
		}
	}()
	return p
}

func (p *testLanePeer) now() int64 { return int64(time.Since(p.start) / time.Millisecond) }

func (p *testLanePeer) flush() {
	if p.channel.ReadyState() != webrtc.DataChannelStateOpen {
		return
	}
	p.mu.Lock()
	packets := p.engine.poll(p.now(), laneQueueTarget)
	p.mu.Unlock()
	for _, packet := range packets {
		_ = p.channel.Send(packet)
	}
}

func (p *testLanePeer) send(stream int, data []byte) {
	p.mu.Lock()
	_ = p.engine.send(stream, data)
	p.mu.Unlock()
	p.flush()
}

func (p *testLanePeer) close() { close(p.stop) }

func (p *testLanePeer) awaitOpen(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for p.channel.ReadyState() != webrtc.DataChannelStateOpen {
		if time.Now().After(deadline) {
			t.Fatalf("the answerer's lane never opened (%s)", p.channel.ReadyState())
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// awaitChannelsOpen blocks until the session reported every label open, in whatever order.
func awaitChannelsOpen(t *testing.T, pair *offerPair, labels ...string) {
	t.Helper()
	want := map[string]bool{}
	for _, l := range labels {
		want[l] = true
	}
	deadline := time.After(15 * time.Second)
	for len(want) > 0 {
		select {
		case opened := <-pair.opens:
			delete(want, opened)
		case <-deadline:
			t.Fatalf("never reported open: %v", sortedKeys(want))
		}
	}
}

func lanePair(t *testing.T) *offerPair {
	return newTestOfferPairConfigured(t, func(c *SessionConfiguration) { c.RdevSCTPChannels = false })
}

func TestLaneSessionCreatesTheLaneAndBulkOnly(t *testing.T) {
	pair := lanePair(t)
	pair.session.mutex.Lock()
	var labels []string
	for label := range pair.session.rdevChannels {
		labels = append(labels, label)
	}
	lane := pair.session.lane
	pair.session.mutex.Unlock()
	if len(labels) != 1 || labels[0] != rdevBulkChannelLabel {
		t.Fatalf("the offer path created SCTP channels %v; want only bulk", labels)
	}
	if lane == nil {
		t.Fatal("the offer path created no lane")
	}
	channel, ok := lane.channel.(*webrtc.DataChannel)
	if !ok {
		t.Fatalf("the lane's carrier is a %T, not pion's data channel", lane.channel)
	}
	if channel.Label() != laneChannelLabel || channel.Ordered() {
		t.Fatal("the lane must be `lane` and unordered: nothing waits behind a hole")
	}
	// RELIABLE (spec §1, "The carrier"): never retransmitted, the browser's SCTP abandoned the lane chunks whose SACKs
	// sat behind the Mac's queue on a slow link and stormed FORWARD-TSN until that owned the link.
	if retransmits := channel.MaxRetransmits(); retransmits != nil {
		t.Fatalf("the lane has maxRetransmits %d; it must be reliable — a never-retransmitted lane let the browser's "+
			"SCTP storm FORWARD-TSN on a slow link (E 1.5–2.1 s against 1.5)", *retransmits)
	}
	if lifetime := channel.MaxPacketLifeTime(); lifetime != nil {
		t.Fatalf("the lane has maxPacketLifeTime %d ms; it must be reliable — a partially reliable lane lets SCTP "+
			"abandon its chunks and storm FORWARD-TSN on a slow link", *lifetime)
	}
}

func TestLaneSessionCarriesTheThreeStreams(t *testing.T) {
	pair := lanePair(t)
	if err := pair.session.SetAnswer(pair.answer); err != nil {
		t.Fatalf("SetAnswer: %v", err)
	}
	remote := newTestLanePeer(pair.awaitRemoteChannel(t, laneChannelLabel))
	defer remote.close()
	remote.awaitOpen(t)
	awaitChannelsOpen(t, pair, "terminal", "input", "control", "bulk")

	key := []byte(`{"t":"key","data":"a","term":"pty:1"}`)
	remote.send(1, key)
	select {
	case m := <-pair.inbound:
		if m.label != "input" || !bytes.Equal(m.data, key) {
			t.Fatalf("the session got %q on %q; want the keystroke on input", m.data, m.label)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the page's keystroke never reached the session")
	}

	frame := bytes.Repeat([]byte{4, 0, 9}, 3000) // 9 KB: spans symbols
	if err := pair.session.SendChannelData("terminal", frame); err != nil {
		t.Fatal(err)
	}
	select {
	case d := <-remote.got:
		if d.stream != 0 || !bytes.Equal(d.data, frame) {
			t.Fatalf("the page got %d bytes on stream %d; want the frame on the terminal stream", len(d.data), d.stream)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the terminal frame never reached the page")
	}
	if _, open := pair.session.ChannelBufferedAmount("control"); !open {
		t.Fatal("control reads not open while the lane is open")
	}
}

// THE PRODUCT'S SESSION BECOMES READY ON THE LANE: input and control's readiness terms are set from the lane's opens
// (becomeOpen → rdevChannelOpened), not from SCTP channels that no longer exist. The SCTP baseline's twin is
// TestOfferSessionCreatesRdevChannelsAndBecomesReady; every other session test runs the baseline (offer_test.go's
// testOfferConfiguration), so without this the product configuration reached readiness only incidentally.
func TestLaneSessionBecomesReady(t *testing.T) {
	pair := lanePair(t)
	if err := pair.session.SetAnswer(pair.answer); err != nil {
		t.Fatalf("SetAnswer: %v", err)
	}
	remote := newTestLanePeer(pair.awaitRemoteChannel(t, laneChannelLabel))
	defer remote.close()
	remote.awaitOpen(t)
	// A bound video track is readiness's other term (see the baseline's twin); added so readiness is reachable, and if
	// the lane's opens were not wired to the channel terms the timeout below names them.
	if _, err := pair.session.AddVideoTrack("win:lane"); err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}
	pair.renegotiate(t)
	if err := pair.session.WaitReady(15 * time.Second); err != nil {
		t.Fatal(err)
	}
}

// SESSION.CLOSE TAKES THE LANE WITH IT, SENDER AND ALL: when Close returns the lane's one sender goroutine has exited,
// its timer is stopped and its channel closed, and nothing more can be sent on its streams.
func TestLaneSessionCloseStopsTheLane(t *testing.T) {
	pair := lanePair(t)
	if err := pair.session.SetAnswer(pair.answer); err != nil {
		t.Fatalf("SetAnswer: %v", err)
	}
	remote := newTestLanePeer(pair.awaitRemoteChannel(t, laneChannelLabel))
	defer remote.close()
	remote.awaitOpen(t)
	awaitChannelsOpen(t, pair, "terminal", "input", "control", "bulk")
	if err := pair.session.SendChannelData("terminal", bytes.Repeat([]byte{7}, 20_000)); err != nil {
		t.Fatal(err)
	}
	select {
	case <-remote.got:
	case <-time.After(10 * time.Second):
		t.Fatal("the terminal frame never reached the page")
	}
	pair.session.mutex.Lock()
	lane := pair.session.lane
	pair.session.mutex.Unlock()
	lane.mu.Lock()
	started := lane.started
	lane.mu.Unlock()
	if !started {
		t.Fatal("precondition: the open lane's sender is running")
	}
	// pion's OnClose stops the sender too (halt) once peer.Close reaches the channel — taken away, so this proves
	// Session.Close stops and waits for it itself rather than racing pion's goroutine.
	lane.channel.(*webrtc.DataChannel).OnClose(func() {})
	if err := pair.session.Close(); err != nil {
		t.Logf("Close: %v", err) // a channel already closing is not this test's subject
	}
	select {
	case <-lane.done:
	default:
		t.Fatal("Session.Close returned with the lane's sender still running")
	}
	lane.mu.Lock()
	closed, timer := lane.closed, lane.timer
	lane.mu.Unlock()
	if !closed || timer != nil {
		t.Fatalf("after Session.Close the lane reads closed=%v with a timer %v; want closed and none", closed, timer != nil)
	}
	if err := lane.send(0, []byte("late")); err == nil {
		t.Fatal("the closed lane took a send")
	}
}

// A QUEUE LEFT WITH LESS ROOM THAN ONE PACKET IS POLLED AGAIN WITHIN 5 ms (rdevLane.flush): pion's low-water
// callback can come a round trip late, and an urgent repair the queue refused waits in the engine where nextWake
// does not see it. With room for a packet, the engine's own wake stands — including "none".
func TestALaneQueueWithoutRoomForAPacketIsPolledAgainSoon(t *testing.T) {
	const now = 1000
	for _, c := range []struct {
		name       string
		engineWake int64
		roomLeft   int
		want       int64
	}{
		{"room for a packet, nothing scheduled", -1, lanePacketMax, -1},
		{"room for a packet, a wake far off", now + 300, lanePacketMax, now + 300},
		{"room for a packet, a wake now", now, 16 * 1024, now},
		{"short of a packet, nothing scheduled", -1, lanePacketMax - 1, now + laneRepollMs},
		{"short of a packet, a wake far off", now + 300, lanePacketMax - 1, now + laneRepollMs},
		{"short of a packet, a wake sooner", now + 2, 0, now + 2},
		{"over target (feedback ignores room)", now + 40, -500, now + laneRepollMs},
	} {
		if got := laneFlushWake(now, c.engineWake, c.roomLeft); got != c.want {
			t.Errorf("%s: wake %d, want %d", c.name, got, c.want)
		}
	}
}

// ---- the glue's own paths, driven directly ----------------------------------------------------------------------

// laneEvents records what a bare lane published to the session, in order: "open <label>" and "<label> <message>".
type laneEvents struct {
	mu     sync.Mutex
	events []string
	hold   chan struct{} // when set, the FIRST open waits on it
	held   chan struct{} // closed once the first open is waiting
}

func (e *laneEvents) opened(label string) {
	e.mu.Lock()
	first := len(e.events) == 0
	hold, held := e.hold, e.held
	e.mu.Unlock()
	if first && hold != nil {
		close(held)
		<-hold
	}
	e.mu.Lock()
	e.events = append(e.events, "open "+label)
	e.mu.Unlock()
}

func (e *laneEvents) deliver(label string, data []byte) {
	e.mu.Lock()
	e.events = append(e.events, label+" "+string(data))
	e.mu.Unlock()
}

func (e *laneEvents) list() []string {
	e.mu.Lock()
	defer e.mu.Unlock()
	return append([]string(nil), e.events...)
}

// newBareLane is a lane around a pion channel that never connects: the test calls the glue's pion-facing paths
// (onOpen, onMessage, flush, connectedAgain) itself, so their ORDER is the test's, not the network's.
func newBareLane(t *testing.T, events *laneEvents, connected func() bool) *rdevLane {
	t.Helper()
	icePort := reserveUDPPort(t)
	signalPort := reserveTCPPort(t)
	for signalPort == icePort {
		signalPort = reserveTCPPort(t)
	}
	api, resources, err := newPeerAPI(PeerConfig{
		ICEPolicy: ICEPolicyStrict,
		LocalIP:   net.ParseIP("127.0.0.1"), RemoteIP: net.ParseIP("127.0.0.1"),
		ICEPort: icePort, SignalPort: signalPort, Recovery: RecoveryNACKRTX, RTXMaxAge: testOfferRTXMaxAge,
	})
	if err != nil {
		t.Fatalf("newPeerAPI: %v", err)
	}
	peer, err := api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		_ = resources.Close()
		t.Fatalf("NewPeerConnection: %v", err)
	}
	unordered := false // the product's lane: unordered and reliable (createRdevDataChannels)
	channel, err := peer.CreateDataChannel(laneChannelLabel, &webrtc.DataChannelInit{Ordered: &unordered})
	if err != nil {
		t.Fatalf("CreateDataChannel: %v", err)
	}
	lane := newRdevLane(channel, 1, connected, events.opened, events.deliver)
	t.Cleanup(func() {
		_ = lane.close()
		_ = peer.Close()
		_ = resources.Close()
	})
	return lane
}

// lanePacketFromPage is one source packet the page's engine would send carrying `message` on `stream`.
func lanePacketFromPage(t *testing.T, stream int, message string) []byte {
	t.Helper()
	page := newLaneEngine(9, 0)
	if err := page.send(stream, []byte(message)); err != nil {
		t.Fatal(err)
	}
	packets := page.poll(0, laneQueueTarget)
	if len(packets) != 1 {
		t.Fatalf("the page's engine made %d packets; want 1", len(packets))
	}
	return packets[0]
}

var laneOpens = []string{"open terminal", "open input", "open control"}

// THE FIRST MESSAGE IS THE IMPLICIT ACK (rdevLane.becomeOpen): the host dials the lane, so pion's OnOpen waits for
// the page's DATA_CHANNEL_ACK — and a lost ACK lets the page's first messages arrive first. They must reach Swift
// AFTER the three opens, the lane must take Swift's reply at once, and the late OnOpen must publish nothing again.
func TestTheFirstLaneMessageOpensTheStreamsBeforeItIsDelivered(t *testing.T) {
	events := &laneEvents{}
	lane := newBareLane(t, events, func() bool { return true })
	hello := `{"t":"client-hello"}`
	lane.onMessage(webrtc.DataChannelMessage{Data: lanePacketFromPage(t, 2, hello)})
	want := append(append([]string(nil), laneOpens...), "control "+hello)
	if got := events.list(); !reflect.DeepEqual(got, want) {
		t.Fatalf("published %q; want %q", got, want)
	}
	if err := lane.send(2, []byte(`{"t":"control-state"}`)); err != nil {
		t.Fatalf("the reply to the page's first message was refused: %v", err)
	}
	if _, open := lane.buffered(2); !open {
		t.Fatal("control reads not open after the page's first message")
	}
	lane.onOpen() // the ACK, late
	if got := events.list(); !reflect.DeepEqual(got, want) {
		t.Fatalf("the late OnOpen published again: %q", got)
	}
}

// ...AND NO DELIVERY OVERTAKES OPENS STILL BEING PUBLISHED: a message arriving while pion's OnOpen is mid-way through
// the three opens waits for them (sync.Once's Do), never lands between them.
func TestALaneMessageWaitsForOpensAlreadyUnderWay(t *testing.T) {
	events := &laneEvents{hold: make(chan struct{}), held: make(chan struct{})}
	lane := newBareLane(t, events, func() bool { return true })
	opened := make(chan struct{})
	go func() {
		lane.onOpen()
		close(opened)
	}()
	<-events.held // OnOpen is publishing, stopped inside the first open
	delivered := make(chan struct{})
	hello := `{"t":"client-hello"}`
	packet := lanePacketFromPage(t, 2, hello)
	go func() {
		lane.onMessage(webrtc.DataChannelMessage{Data: packet})
		close(delivered)
	}()
	select {
	case <-delivered:
		t.Fatalf("the message was delivered while the opens were still being published: %q", events.list())
	case <-time.After(200 * time.Millisecond):
	}
	close(events.hold)
	<-opened
	<-delivered
	want := append(append([]string(nil), laneOpens...), "control "+hello)
	if got := events.list(); !reflect.DeepEqual(got, want) {
		t.Fatalf("published %q; want %q", got, want)
	}
}

// A LANE STUCK ACROSS AN OUTAGE IS NOT CLOSED BEFORE THE RECONNECT RESETS IT (rdevLane.linkUp): pion stores
// `connected` before the handler that reaches connectedAgain runs, so for a moment the link reads up while the
// stuck clocks still hold the outage. Only a stuck lane on a link connectedAgain has seen up closes.
func TestALaneStuckAcrossAnOutageIsNotClosedBeforeTheReconnectResetsIt(t *testing.T) {
	var connected atomic.Bool
	events := &laneEvents{}
	lane := newBareLane(t, events, connected.Load)
	isClosed := func() bool {
		lane.mu.Lock()
		defer lane.mu.Unlock()
		return lane.closed
	}
	// stuckSince makes the engine report a hole it could not fill for 40 s.
	stuckSince := func() {
		lane.mu.Lock()
		lane.start = lane.start.Add(-40 * time.Second)
		lane.engine.holeSince = lane.now() - 40_000
		lane.mu.Unlock()
	}
	step := func(name string, wantClosed bool) {
		t.Helper()
		lane.flush()
		if isClosed() != wantClosed {
			t.Fatalf("%s: the lane closed=%v; want %v", name, isClosed(), wantClosed)
		}
	}

	lane.onOpen()
	connected.Store(true)
	lane.connectedAgain()
	step("connected, not stuck", false)
	connected.Store(false)
	step("the outage begins", false)
	stuckSince()
	step("stuck through the outage", false)
	connected.Store(true) // pion stored `connected`; its handler has not reached connectedAgain yet
	step("the link reads up before connectedAgain", false)
	lane.connectedAgain()
	step("after connectedAgain the clocks start over", false)
	stuckSince() // NEGATIVE CONTROL: the same stuck lane on a link connectedAgain saw up does close
	step("stuck on a connected link", true)
	if got := fmt.Sprint(events.list()); got != fmt.Sprint(laneOpens) {
		t.Fatalf("published %s; want only the opens", got)
	}
}

// ---- the one sender ---------------------------------------------------------------------------------------------

// laneWire is a carrier double: it records every packet the lane hands it, in order, yielding first so a second
// sender could overtake — and holds them as pion counts its buffered amount, until acknowledged: never, unless
// `drains` (then it reads empty, the room always whole).
type laneWire struct {
	mu      sync.Mutex
	packets [][]byte
	held    int
	drains  bool
	closed  bool
}

func (w *laneWire) Send(packet []byte) error {
	runtime.Gosched()
	w.mu.Lock()
	defer w.mu.Unlock()
	w.packets = append(w.packets, append([]byte(nil), packet...))
	w.held += len(packet)
	return nil
}

func (w *laneWire) BufferedAmount() uint64 {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.drains {
		return 0
	}
	return uint64(w.held)
}

func (w *laneWire) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.closed = true
	return nil
}

func (w *laneWire) sent() ([][]byte, int, bool) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return append([][]byte(nil), w.packets...), w.held, w.closed
}

func newWireLane(wire *laneWire, connected func() bool) *rdevLane {
	return newRdevLaneOver(wire, 1, connected, func(string) {}, func(string, []byte) {})
}

// THE LANE HANDS PION ITS PACKETS IN THE ORDER IT NUMBERED THEM (rdevLane.run), whoever asks for the flush: Swift's
// threads sending on all three streams, pion's read goroutine delivering the page's feedback, the timer and the
// low-water callback kicking — all at once. Two flushes interleaving put pkt N+1 on the wire before N, and the page,
// which records only the newest pkt, counted N lost for its whole 256-packet window. Run under -race.
func TestTheLaneHandsPionItsPacketsInTheOrderItNumberedThem(t *testing.T) {
	wire := &laneWire{drains: true}
	lane := newWireLane(wire, func() bool { return true })
	defer func() { _ = lane.close() }()
	lane.onOpen()
	page := newLaneEngine(9, 0)
	var senders sync.WaitGroup
	for g := 0; g < 8; g++ {
		senders.Add(1)
		go func(g int) {
			defer senders.Done()
			for i := 0; i < 150; i++ {
				if err := lane.send(g%laneStreams, laneTestMessage(g%laneStreams, i, 40+i%300)); err != nil {
					t.Error(err)
					return
				}
				if i%7 == 0 {
					lane.kick() // the timer, OnBufferedAmountLow
				}
			}
		}(g)
	}
	// The page: it reads what reached the wire and answers with feedback on pion's read goroutine (onMessage), so the
	// engine is acknowledged — its 512-symbol window never fills — while the senders run.
	stopPage := make(chan struct{})
	pageDone := make(chan struct{})
	go func() {
		defer close(pageDone)
		read, start := 0, time.Now()
		for {
			select {
			case <-stopPage:
				return
			case <-time.After(time.Millisecond):
			}
			packets, _, _ := wire.sent()
			now := int64(time.Since(start) / time.Millisecond)
			for ; read < len(packets); read++ {
				page.receive(packets[read], now)
			}
			for _, feedback := range page.poll(now, laneQueueTarget) {
				lane.onMessage(webrtc.DataChannelMessage{Data: feedback})
			}
		}
	}()
	senders.Wait()
	deadline := time.Now().Add(10 * time.Second)
	for {
		lane.mu.Lock()
		idle := !lane.engine.pending()
		numbered := lane.engine.pkt
		lane.mu.Unlock()
		packets, _, _ := wire.sent()
		if idle && uint32(len(packets)) == numbered {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the lane never drained: %d packets on the wire, %d numbered", len(packets), numbered)
		}
		time.Sleep(time.Millisecond)
	}
	close(stopPage)
	<-pageDone
	packets, _, _ := wire.sent()
	if len(packets) < 100 {
		t.Fatalf("only %d packets: the test made no traffic to reorder", len(packets))
	}
	for i, packet := range packets {
		if pkt := binary.BigEndian.Uint32(packet[1:5]); pkt != uint32(i) {
			t.Fatalf("the wire's packet %d is pkt %d: pion was handed the lane's packets out of the order it numbered them", i, pkt)
		}
	}
}

// ...AND HOWEVER MANY ASK AT ONCE, PION NEVER HOLDS MORE THAN THE QUEUE TARGET: the room is measured by the one sender
// with every packet it handed pion before already counted. Flushing from every caller, each read the room before the
// others' packets landed (the ledger's "concurrent flushes can overshoot room, ~2× queueTarget"). Nothing is
// acknowledged here, so the target is its 16 KB floor and no feedback goes.
func TestConcurrentSendsNeverOvershootTheLanesQueueTarget(t *testing.T) {
	wire := &laneWire{}
	lane := newWireLane(wire, func() bool { return true })
	defer func() { _ = lane.close() }()
	lane.onOpen()
	var senders sync.WaitGroup
	for g := 0; g < 8; g++ {
		senders.Add(1)
		go func(g int) {
			defer senders.Done()
			for i := 0; i < 40; i++ {
				if err := lane.send(0, laneTestMessage(0, g*1000+i, 1000)); err != nil {
					t.Error(err)
					return
				}
				lane.kick()
			}
		}(g)
	}
	senders.Wait()
	time.Sleep(50 * time.Millisecond) // the sender's 5 ms re-polls, finding no room
	_, held, _ := wire.sent()
	if held > laneQueueTarget {
		t.Fatalf("pion was handed %d B for the lane with nothing acknowledged; the queue target is %d B", held, laneQueueTarget)
	}
	if held < laneQueueTarget-lanePacketMax {
		t.Fatalf("pion was handed only %d B: the lane never reached its target, so nothing was bounded", held)
	}
}

// CLOSING THE LANE STOPS ITS SENDER AND LEAVES NOTHING BEHIND: close returns with the goroutine gone and the channel
// closed, and a kick after it sends nothing. A lane that never opened never had a sender, and closes at once; pion's
// OnClose stops the sender without waiting; a stuck lane closes itself from the sender without waiting on itself.
func TestClosingTheLaneStopsItsSender(t *testing.T) {
	wire := &laneWire{drains: true}
	lane := newWireLane(wire, func() bool { return true })
	lane.onOpen()
	for i := 0; i < 50; i++ {
		if err := lane.send(0, laneTestMessage(0, i, 500)); err != nil {
			t.Fatal(err)
		}
	}
	if err := lane.close(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-lane.done:
	default:
		t.Fatal("close returned with the lane's sender still running")
	}
	packets, _, closed := wire.sent()
	if !closed {
		t.Fatal("close left the lane's channel open")
	}
	lane.kick()
	time.Sleep(20 * time.Millisecond)
	if after, _, _ := wire.sent(); len(after) != len(packets) {
		t.Fatalf("a kick after close sent %d packets", len(after)-len(packets))
	}

	never := newWireLane(&laneWire{}, func() bool { return true })
	closedAt := make(chan struct{})
	go func() { _ = never.close(); close(closedAt) }()
	select {
	case <-closedAt:
	case <-time.After(5 * time.Second):
		t.Fatal("closing a lane that never opened waited for a sender it never had")
	}

	byPion := newWireLane(&laneWire{drains: true}, func() bool { return true })
	byPion.onOpen()
	byPion.onClose()
	select {
	case <-byPion.done:
	case <-time.After(5 * time.Second):
		t.Fatal("pion's OnClose did not stop the lane's sender")
	}

	stuckWire := &laneWire{drains: true}
	stuck := newWireLane(stuckWire, func() bool { return true })
	stuck.onOpen()
	stuck.connectedAgain()
	stuck.mu.Lock()
	stuck.engine.violated = true // a broken peer: stuck at once on a connected link
	stuck.mu.Unlock()
	stuck.kick()
	select {
	case <-stuck.done:
	case <-time.After(5 * time.Second):
		t.Fatal("a stuck lane's sender did not close the lane and exit")
	}
	if _, _, closed := stuckWire.sent(); !closed {
		t.Fatal("the stuck lane's sender exited without closing its channel")
	}
	if err := stuck.close(); err != nil { // the session's close after it: returns, waiting for a sender already gone
		t.Fatal(err)
	}
}

// THE LANE'S STREAMS ARE THE ABI'S FIRST THREE CHANNELS, in order: laneStreamLabels is written out beside
// rdevChannelLabels (rdev_lane.go), and a stream published under the wrong label would put terminal bytes on input.
func TestTheLaneStreamsAreTheABIsFirstThreeChannels(t *testing.T) {
	if fmt.Sprint(laneStreamLabels[:]) != fmt.Sprint(rdevChannelLabels[:laneStreams]) {
		t.Fatalf("the lane's streams are %v; the ABI's slots 0–2 are %v", laneStreamLabels, rdevChannelLabels[:laneStreams])
	}
}

// NO WAKEUP IS LOST: with pion's queue full a message waits in the lane; when the queue drains with no other event —
// no OnBufferedAmountLow (pion's count need not cross the low-water mark), no message, no send — the sender's own
// re-poll still finds the room and hands the message over within a few milliseconds (laneRepollMs).
func TestALaneQueueThatDrainsSilentlyIsUsedAtOnce(t *testing.T) {
	wire := &laneWire{}
	lane := newWireLane(wire, func() bool { return true })
	defer func() { _ = lane.close() }()
	lane.onOpen()
	wire.mu.Lock()
	wire.held = 1 << 20 // pion's queue far past the target: no room
	wire.mu.Unlock()
	if err := lane.send(1, []byte(`{"t":"key","data":"a","term":"pty:1"}`)); err != nil {
		t.Fatal(err)
	}
	time.Sleep(30 * time.Millisecond)
	if packets, _, _ := wire.sent(); len(packets) != 0 {
		t.Fatalf("precondition: with no room nothing goes, yet %d packets did", len(packets))
	}
	wire.mu.Lock()
	wire.held = 0 // drained — and nothing tells the lane
	wire.mu.Unlock()
	drained := time.Now()
	for {
		if packets, _, _ := wire.sent(); len(packets) > 0 {
			if waited := time.Since(drained); waited > 50*time.Millisecond {
				t.Fatalf("the message went %v after the room opened; the re-poll is %d ms", waited, laneRepollMs)
			}
			return
		}
		if time.Since(drained) > 2*time.Second {
			t.Fatal("the room opened and the waiting message never went: a lost wakeup")
		}
		time.Sleep(time.Millisecond)
	}
}

// THE LANE SAYS WHAT CROSSED PION (summary, every laneStatsEvery): a lane that stalls on a path no measurement covered
// must leave its state in the host's log. The line counts what the sender handed the carrier and what the engine
// holds — read here after one message.
func TestTheLaneSummarySaysWhatCrossedPion(t *testing.T) {
	wire := &laneWire{drains: true}
	lane := newWireLane(wire, func() bool { return true })
	if got := lane.summary(); !strings.HasPrefix(got, "[lane] tx 0 pkts 0 KiB refused 0 · rx 0 pkts") {
		t.Fatalf("a fresh lane's summary: %q", got)
	}
	lane.onOpen()
	defer lane.stop()
	if err := lane.send(0, []byte("hello")); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for {
		packets, _, _ := wire.sent()
		if len(packets) > 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the lane sent nothing")
		}
		time.Sleep(time.Millisecond)
	}
	got := lane.summary()
	if strings.HasPrefix(got, "[lane] tx 0 pkts") || !strings.Contains(got, "out next=1 acked<0 held=1") {
		t.Fatalf("after one message the summary should count the packet and the held symbol: %q", got)
	}
}

// AFTER THE LINK DROPS AND COMES BACK, 5 s WITH NO PROGRESS CLOSES THE LANE (laneStalledAfterReconnectMs): a browser's
// SCTP may hold the page's packets in its backoff after a network blink (2026-10-13, a phone over TURN), and the page
// rebuilds on a fresh association only once the lane closes. A link that never dropped keeps the engine's 30 s.
func TestALaneStalledAfterTheLinkCameBackCloses(t *testing.T) {
	for _, c := range []struct {
		name      string
		dropped   bool
		wantClose bool
	}{{"the link dropped and came back", true, true}, {"the link never dropped", false, false}} {
		t.Run(c.name, func(t *testing.T) {
			wire := &laneWire{drains: true} // what the lane sends is never acknowledged
			lane := newWireLane(wire, func() bool { return true })
			defer lane.stop()
			lane.connectedAgain() // the first connection
			lane.onOpen()
			if c.dropped {
				lane.linkLost()
				lane.connectedAgain()
			}
			if err := lane.send(0, []byte("k")); err != nil {
				t.Fatal(err)
			}
			for sent := time.Now().Add(time.Second); ; time.Sleep(time.Millisecond) { // sent (and held) before time moves
				if packets, _, _ := wire.sent(); len(packets) > 0 {
					break
				}
				if time.Now().After(sent) {
					t.Fatal("the lane sent nothing")
				}
			}
			lane.mu.Lock()
			lane.start = lane.start.Add(-(laneStalledAfterReconnectMs + 1000) * time.Millisecond) // 6 s go by
			lane.mu.Unlock()
			lane.kick()
			deadline := time.Now().Add(time.Second)
			for time.Now().Before(deadline) {
				if _, _, closed := wire.sent(); closed {
					break
				}
				time.Sleep(5 * time.Millisecond)
			}
			if _, _, closed := wire.sent(); closed != c.wantClose {
				t.Fatalf("closed=%v after 6 s with no progress; want %v", closed, c.wantClose)
			}
		})
	}
}
