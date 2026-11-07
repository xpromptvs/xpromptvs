package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"testing"
)

// THE LANE ENGINE OVER A SIMULATED LINK (docs/superpowers/specs/2026-10-12-terminal-lane-design.md §3–§5): two
// engines on a fake millisecond clock, seeded loss — independent or in bursts —, a one-way delay, reordering and
// duplication. Side 0 is "a", side 1 is "b". web/test/lane.test.ts runs the same cases against lane.ts, on the SAME
// pipe: the same generator (mulberry32), drawn in the same order, so a seed is one run in both languages — which is
// what lets the parity digest (protocol/fixtures/lane-parity.json) hold them to one behaviour.
type laneFlight struct {
	at   int64
	to   int
	data []byte
}

type lanePacketLog struct {
	at     int64
	packet []byte
	lost   bool
}

type lanePipe struct {
	t         *testing.T
	random    func() float64 // mulberry32, as lane.test.ts's
	engines   [2]*laneEngine
	loss      [2]float64 // indexed by the SENDER
	burst     float64    // mean burst length in packets; ≤ 1 is independent loss
	bad       [2]bool
	delay     int64
	reorder   float64 // a packet's chance of 1–8 ms extra, so a later one can overtake it
	duplicate float64
	drop      func(from int, packet []byte) bool // a targeted loss on top
	// late > 0: a lost packet still arrives, `late` ms after it would have — the reliable carrier's retransmission
	// (spec §1, "The carrier"), a copy the lane's own repair has usually made redundant. No draw is made for it.
	late int64
	// room: what pion's queue may still take for a side's poll (nil: laneQueueTarget) — 0 for a stretch at zero room.
	room func(side int, now int64) int
	// A side whose timers never run: it polls only when a packet arrives (a hidden or suspended page).
	pollOnArrivalOnly [2]bool
	inFlight          []laneFlight
	now               int64
	got               [2][laneStreams][][]byte
	gotAt             [2][laneStreams][]int64
	sent              [2][]lanePacketLog
	lastSent          [2]int64
	maxQuiet          [2]int64 // the longest silence while holding unacknowledged data
	// A side whose last poll filled its room. pion's queue drains by the next millisecond and the glue's
	// OnBufferedAmountLow polls again, so what the room held back — gap, timer or proactive repair — goes then.
	filled [2]bool
}

func newLanePipe(t *testing.T, seed int64, initial uint64) *lanePipe {
	return &lanePipe{t: t, random: laneMulberry32(uint32(seed)),
		engines: [2]*laneEngine{newLaneEngine(1, initial), newLaneEngine(2, initial)}}
}

// laneMulberry32 is lane.test.ts's generator, bit for bit: uint32 arithmetic is what Math.imul and `>>> 0` compute.
func laneMulberry32(seed uint32) func() float64 {
	a := seed
	return func() float64 {
		a += 0x6d2b79f5
		t := a
		t = (t ^ (t >> 15)) * (t | 1)
		t ^= t + (t^(t>>7))*(t|61)
		return float64(t^(t>>14)) / 4294967296
	}
}

func (p *lanePipe) lose(from int) bool {
	loss := p.loss[from]
	if loss <= 0 {
		return false
	}
	if loss >= 1 {
		return true
	}
	if p.burst <= 1 {
		return p.random() < loss
	}
	// Gilbert–Elliott: every packet sent in the bad state is lost; bursts average `burst` packets and the
	// stationary share of the bad state is `loss`.
	if p.bad[from] {
		if p.random() < 1/p.burst {
			p.bad[from] = false
		}
	} else if p.random() < loss/(p.burst*(1-loss)) {
		p.bad[from] = true
	}
	return p.bad[from]
}

func (p *lanePipe) transmit(from int, packets [][]byte) {
	if len(packets) > 0 {
		p.lastSent[from] = p.now
	}
	for _, packet := range packets {
		lost := p.lose(from) || (p.drop != nil && p.drop(from, packet))
		p.sent[from] = append(p.sent[from], lanePacketLog{p.now, packet, lost})
		if lost {
			if p.late > 0 {
				p.inFlight = append(p.inFlight, laneFlight{p.now + p.delay + p.late, 1 - from, packet})
			}
			continue
		}
		copies := 1
		if p.random() < p.duplicate {
			copies = 2
		}
		for i := 0; i < copies; i++ {
			at := p.now + p.delay
			if p.random() < p.reorder {
				at += 1 + int64(p.random()*8)
			}
			p.inFlight = append(p.inFlight, laneFlight{at, 1 - from, packet})
		}
	}
}

// step advances the clock 1 ms: arrivals first, then each side polls when something arrived, a timer is due, it has
// data to send or its queue drained after a poll that filled it.
func (p *lanePipe) step() {
	p.now++
	var due []laneFlight
	rest := p.inFlight[:0]
	for _, f := range p.inFlight {
		if f.at <= p.now {
			due = append(due, f)
		} else {
			rest = append(rest, f)
		}
	}
	p.inFlight = rest
	var arrived [2]bool
	for _, f := range due {
		e := p.engines[f.to]
		e.receive(f.data, p.now)
		arrived[f.to] = true
		for _, d := range e.takeDelivered() {
			p.got[f.to][d.stream] = append(p.got[f.to][d.stream], d.data)
			p.gotAt[f.to][d.stream] = append(p.gotAt[f.to][d.stream], p.now)
		}
	}
	for side, e := range p.engines {
		if p.pollOnArrivalOnly[side] && !arrived[side] {
			continue
		}
		wake := e.nextWake(p.now)
		if arrived[side] || e.pending() || p.filled[side] || (wake >= 0 && wake <= p.now) {
			room := laneQueueTarget
			if p.room != nil {
				room = p.room(side, p.now)
			}
			packets := e.poll(p.now, room)
			p.transmit(side, packets)
			size := 0
			for _, packet := range packets {
				size += len(packet)
			}
			p.filled[side] = size > room-lanePacketMax
		}
		if e.nextESI > e.heldFrom && p.now-p.lastSent[side] > p.maxQuiet[side] {
			p.maxQuiet[side] = p.now - p.lastSent[side]
		}
	}
}

func (p *lanePipe) runUntil(done func() bool, limit int64) {
	for p.now < limit && !done() {
		p.step()
	}
}

// laneTestMessage is message i of a stream: its identity first, then a pattern, `size` bytes in all.
func laneTestMessage(stream, i, size int) []byte {
	head := []byte(fmt.Sprintf("%d:%d:", stream, i))
	out := make([]byte, max(size, len(head)))
	copy(out, head)
	for j := len(head); j < len(out); j++ {
		out[j] = byte(stream*67 + i*13 + j*7)
	}
	return out
}

type laneWant [2][laneStreams][][]byte // what each side SENT, per stream

func (p *lanePipe) sendAll(want laneWant) {
	for side := range want {
		for stream, messages := range want[side] {
			for _, m := range messages {
				if err := p.engines[side].send(stream, m); err != nil {
					p.t.Fatalf("send: %v", err)
				}
			}
		}
	}
}

func (p *lanePipe) delivered(want laneWant) bool {
	for side := range want {
		for stream := range want[side] {
			if len(p.got[1-side][stream]) < len(want[side][stream]) {
				return false
			}
		}
	}
	return true
}

func (p *lanePipe) assertDelivered(want laneWant) {
	p.t.Helper()
	for side := range want {
		for stream, messages := range want[side] {
			got := p.got[1-side][stream]
			if len(got) != len(messages) {
				p.t.Fatalf("side %d stream %d: %d of %d messages delivered at %d ms", side, stream, len(got), len(messages), p.now)
			}
			for i := range messages {
				if !bytes.Equal(got[i], messages[i]) {
					p.t.Fatalf("side %d stream %d: message %d is %q…, want %q…", side, stream, i, laneTestPrefix(got[i]), laneTestPrefix(messages[i]))
				}
			}
		}
	}
}

func laneTestPrefix(b []byte) []byte { return b[:min(len(b), 16)] }

func laneTypicalTraffic() laneWant {
	var w laneWant
	for i := 0; i < 300; i++ {
		w[0][0] = append(w[0][0], laneTestMessage(0, i, 1+(i*97)%3000)) // a's terminal output
	}
	for i := 0; i < 100; i++ {
		w[0][2] = append(w[0][2], laneTestMessage(2, i, 40+i%200)) // a's control
		w[1][2] = append(w[1][2], laneTestMessage(2, i, 30+i%50))  // b's control
	}
	for i := 0; i < 200; i++ {
		w[1][1] = append(w[1][1], laneTestMessage(1, i, 38)) // b's keystrokes
	}
	return w
}

func TestTheLaneDeliversEveryMessageInOrder(t *testing.T) {
	cases := []struct {
		name                     string
		loss, reorder, duplicate float64
		burst                    float64
	}{
		{"no loss", 0, 0, 0, 0},
		{"5% loss", 0.05, 0, 0, 0},
		{"15% loss", 0.15, 0, 0, 0},
		{"30% loss", 0.30, 0, 0, 0},
		{"5% loss, reordered and duplicated", 0.05, 0.2, 0.1, 0},
		{"5% loss in bursts of 4", 0.05, 0, 0, 4},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			p := newLanePipe(t, 7, 0)
			p.loss, p.delay, p.reorder, p.duplicate, p.burst = [2]float64{c.loss, c.loss}, 40, c.reorder, c.duplicate, c.burst
			want := laneTypicalTraffic()
			p.sendAll(want)
			p.runUntil(func() bool { return p.delivered(want) }, 180_000)
			p.assertDelivered(want)
			for side := range p.maxQuiet {
				if p.maxQuiet[side] > laneTimerMaxMs+1 {
					t.Fatalf("side %d sat silent %d ms holding unacknowledged data; the timer's cap is %d", side, p.maxQuiet[side], laneTimerMaxMs)
				}
			}
		})
	}
}

// A HOLE IN THE TERMINAL STREAM DOES NOT HOLD CONTROL: each stream delivers as soon as ITS bytes are contiguous.
func TestAHoleInTheTerminalStreamDoesNotHoldControl(t *testing.T) {
	p := newLanePipe(t, 3, 0)
	p.delay = 40
	p.drop = func(from int, _ []byte) bool { return from == 0 && p.now <= 20 } // the terminal symbol AND its tail repair
	if err := p.engines[0].send(0, []byte("terminal, sent first")); err != nil {
		t.Fatal(err)
	}
	p.runUntil(func() bool { return p.now >= 21 }, 21)
	if err := p.engines[0].send(2, []byte("control, sent second")); err != nil {
		t.Fatal(err)
	}
	p.runUntil(func() bool { return len(p.got[1][0]) == 1 && len(p.got[1][2]) == 1 }, 5000)
	if len(p.gotAt[1][2]) != 1 || len(p.gotAt[1][0]) != 1 {
		t.Fatalf("delivered terminal %d, control %d", len(p.gotAt[1][0]), len(p.gotAt[1][2]))
	}
	if control, terminal := p.gotAt[1][2][0], p.gotAt[1][0][0]; control >= terminal {
		t.Fatalf("control arrived at %d ms, the terminal at %d: control waited for the terminal's hole", control, terminal)
	}
}

// A LONE LOST PACKET IS REBUILT FROM THE TAIL REPAIR: within 10 ms + the one-way delay of being sent.
func TestALoneLostPacketIsRebuiltWithinTheTail(t *testing.T) {
	p := newLanePipe(t, 5, 0)
	p.delay = 40
	p.drop = func(from int, packet []byte) bool { return from == 0 && packet[0] == laneTypeSource }
	if err := p.engines[0].send(1, []byte(`{"t":"key","data":"a","term":"pty:1"}`)); err != nil {
		t.Fatal(err)
	}
	p.runUntil(func() bool { return len(p.got[1][1]) == 1 }, 2000)
	if len(p.gotAt[1][1]) != 1 {
		t.Fatal("the keystroke never arrived")
	}
	if at, limit := p.gotAt[1][1][0], int64(1+laneTailFirstMs)+p.delay+1; at > limit {
		t.Fatalf("the keystroke arrived at %d ms; the tail repair should rebuild it by %d", at, limit)
	}
}

// A LOST BURST END IS REPAIRED AT THE FIRST FEEDBACK AFTER IT, not by the timer one symbol at a time: the receiver
// decodes nothing above the loss, so no reported range shows it, but every lost symbol went more than laneReorderMs
// before the newest packet the receiver echoes (RACK).
func TestALostBurstEndIsRepairedAtTheFirstFeedback(t *testing.T) {
	const cut = 80 // every source from ESI 80 on is lost, and every repair sent with the burst
	p := newLanePipe(t, 43, 0)
	p.delay = 40
	p.drop = func(from int, packet []byte) bool {
		if from != 0 {
			return false
		}
		d, err := decodeLanePacket(packet)
		if err != nil {
			t.Fatal(err)
		}
		switch d.kind {
		case laneTypeSource:
			return d.esi >= cut
		case laneTypeRepair:
			return p.now <= 20 // the burst's proportional repairs and its tail at +10
		}
		return false
	}
	var want laneWant
	for i := 0; i < 107; i++ { // 101 symbols: ESIs 0..100
		want[0][0] = append(want[0][0], laneTestMessage(0, i, 1000))
	}
	p.sendAll(want)
	stuck := false
	p.runUntil(func() bool {
		stuck = stuck || p.engines[1].stuck(p.now)
		return p.delivered(want)
	}, 60_000)
	p.assertDelivered(want)
	a := p.engines[0]
	if lost := a.nextESI - cut; lost < 20 {
		t.Fatalf("only %d source symbols lost; the test needs a burst end of ~20", lost)
	}
	var lastSource int64
	for _, s := range p.sent[0] {
		if s.packet[0] == laneTypeSource {
			lastSource = s.at
		}
	}
	// The bound, from the rules. The burst's last packet is its tail repair, at lastSource + laneTailFirstMs; it arms
	// the timer with the INITIAL 200 ms (no round trip is measured until the first feedback reaches a, 2 × delay after
	// the burst, and progress resets the backoff, not the deadline). The timer's repair reaches b one delay later and
	// names ESIs above b's newest, so b reports the hole at once; that report reaches a one delay later and echoes the
	// timer repair's ts — ~200 ms after every lost symbol went —, so all k are missing and draw k + 1 gap repairs:
	// 14 of ~1.1 KB fit one poll's 16 KB, the rest go 1 ms later, and they reach b one delay after that.
	bound := lastSource + laneTailFirstMs + laneTimerInitialMs + 3*p.delay + 1
	if at := p.gotAt[1][0][len(p.gotAt[1][0])-1]; at > bound {
		t.Fatalf("the burst end was delivered at %d ms; the first feedback after the loss should repair it by %d", at, bound)
	}
	if stuck {
		t.Fatal("the receiver was declared stuck")
	}
}

// RACK SPARES SYMBOLS STILL IN FLIGHT: only a symbol sent more than laneReorderMs before the newest packet the
// receiver echoes is missing — the rest may simply not have arrived yet. (The pipe has no bandwidth limit, so the
// delivery tests REWARD over-repair; this is what holds the rule.)
func TestRACKSparesSymbolsStillInFlight(t *testing.T) {
	e := newLaneEngine(51, 0)
	for i := 0; i < 30; i++ {
		if err := e.send(2, []byte{byte(i)}); err != nil {
			t.Fatal(err)
		}
		e.poll(int64(i), laneQueueTarget) // one symbol each: ESIs 0..29 at 0..29 ms
	}
	e.poll(39, laneQueueTarget) // the tail repair goes; nothing else is owed

	// 0..9 acknowledged, nothing decoded above, the echo naming the packet sent at 25 ms: 10..14 went before
	// 25 − laneReorderMs and are missing (k = 5); 15..29 may still be in flight. One window, [10, 30): k + 1 repairs.
	e.receive(encodeLaneFeedback(0, 59, laneFeedback{cumESI: 10, echoTS: 25}), 60)
	repairs := 0
	for _, packet := range e.poll(60, laneQueueTarget) {
		d, err := decodeLanePacket(packet)
		if err != nil {
			t.Fatal(err)
		}
		if d.kind != laneTypeRepair || d.esi != 10 || d.count != 20 {
			t.Fatalf("sent %+v; want repairs over [10, 30)", d)
		}
		repairs++
	}
	if repairs != 6 {
		t.Fatalf("%d repairs; want 5 + 1 — only 10..14 went more than %d ms before the echo", repairs, laneReorderMs)
	}
}

// A REPORTED GAP DRAWS k + 1 REPAIRS OVER ITS WINDOW — and the same report within a round trip draws none.
func TestAReportedGapDrawsKPlusOneRepairs(t *testing.T) {
	e := newLaneEngine(9, 0)
	for i := 0; i < 10; i++ {
		if err := e.send(2, []byte{byte(i)}); err != nil {
			t.Fatal(err)
		}
		e.poll(int64(i), laneQueueTarget) // one symbol each: ESIs 0..9 at 0..9 ms
	}
	e.poll(19, laneQueueTarget) // the tail repair goes; nothing else is owed

	report := laneFeedback{cumESI: 2, ranges: []laneRange{{3, 2}, {6, 4}}, echoTS: 9} // 2 and 5 missing
	e.receive(encodeLaneFeedback(0, 10, report), 20)
	repairs := 0
	for _, packet := range e.poll(20, laneQueueTarget) {
		d, err := decodeLanePacket(packet)
		if err != nil {
			t.Fatal(err)
		}
		if d.kind != laneTypeRepair || d.esi != 2 || d.count != 8 {
			t.Fatalf("sent %+v; want repairs over [2, 10)", d)
		}
		repairs++
	}
	if repairs != 3 {
		t.Fatalf("%d repairs for 2 missing symbols; want 2 + 1", repairs)
	}
	e.receive(encodeLaneFeedback(1, 11, report), 25)
	if again := e.poll(25, laneQueueTarget); len(again) != 0 {
		t.Fatalf("the same report within a round trip drew %d more packets", len(again))
	}
}

// THE TIMER DOUBLES TO ITS 1 s CAP AND NEVER GIVES UP when no feedback ever comes back.
func TestTheTimerDoublesToItsCap(t *testing.T) {
	p := newLanePipe(t, 11, 0)
	p.delay = 40
	p.loss = [2]float64{0, 1} // nothing from b ever arrives
	if err := p.engines[0].send(1, []byte("k")); err != nil {
		t.Fatal(err)
	}
	p.runUntil(func() bool { return p.now >= 6000 }, 6000)
	var at []int64
	for _, s := range p.sent[0] {
		if s.packet[0] == laneTypeRepair {
			at = append(at, s.at)
		}
	}
	// The tail at +10 re-arms the timer; then it fires 200 ms after the last send, doubling to the 1 s cap.
	want := []int64{11, 211, 611, 1411, 2411, 3411, 4411, 5411}
	if fmt.Sprint(at) != fmt.Sprint(want) {
		t.Fatalf("repairs at %v ms, want %v", at, want)
	}
}

// THE TIMER STAYS UNDER ITS 1 s CAP AT A LONG ROUND TRIP: the first sample makes the base srtt + 4·rttvar = 3 × the
// round trip, and progress must not arm a timeout past the cap with it.
func TestTheTimerStaysUnderItsCapAtALongRoundTrip(t *testing.T) {
	p := newLanePipe(t, 53, 0)
	p.delay = 250
	p.drop = func(from int, _ []byte) bool { return from == 1 && p.now > 300 } // only b's first feedback gets back
	if err := p.engines[0].send(1, []byte("k1")); err != nil {
		t.Fatal(err)
	}
	p.runUntil(func() bool { return p.now >= 600 }, 600)
	a := p.engines[0]
	if a.nextESI != a.heldFrom || a.rtoBase() <= laneTimerMaxMs {
		t.Fatalf("precondition: k1 acknowledged (%d held) with a base timeout past the cap (%.0f ms)", a.nextESI-a.heldFrom, a.rtoBase())
	}
	if err := a.send(1, []byte("k2")); err != nil { // never acknowledged
		t.Fatal(err)
	}
	p.runUntil(func() bool { return p.now >= 6000 }, 6000)
	// k2 at 601 and its tail at 611; nothing comes back, so the timer fires at the cap, 1000 ms after each send — the
	// longest silence, read the millisecond before, is laneTimerMaxMs − 1.
	if p.maxQuiet[0] != laneTimerMaxMs-1 {
		t.Fatalf("the sender sat silent %d ms holding data; the timer's cap is %d", p.maxQuiet[0], laneTimerMaxMs)
	}
}

// THE TIMER REPAIRS THE OLDEST WINDOW, NOT ONLY THE NEWEST: a hole at heldFrom more than 64 symbols below the newest,
// the newest itself acknowledged, the gap repairs lost and no feedback after — only the timer can reach it.
func TestTheTimerRepairsTheOldestWindow(t *testing.T) {
	e := newLaneEngine(47, 0)
	for i := 0; i < 100; i++ {
		if err := e.send(2, []byte{byte(i)}); err != nil {
			t.Fatal(err)
		}
		e.poll(int64(i), laneQueueTarget) // one symbol each: ESIs 0..99 at 0..99 ms
	}
	e.poll(109, laneQueueTarget) // the tail repair goes; nothing else is owed

	// 0..1 acknowledged and 3..99 decoded: a hole at 2, the newest acknowledged. The gap repairs it draws are lost.
	report := laneFeedback{cumESI: 2, ranges: []laneRange{{3, 97}}, echoTS: 99}
	e.receive(encodeLaneFeedback(0, 139, report), 140)
	if len(e.poll(140, laneQueueTarget)) == 0 {
		t.Fatal("the hole drew no gap repair")
	}
	for now := int64(141); now <= 140+laneTimerMaxMs; now++ {
		packets := e.poll(now, laneQueueTarget)
		if len(packets) == 0 {
			continue
		}
		var windows []string // nothing else is owed, so the first packets after the gap repairs are the timer's
		for _, packet := range packets {
			d, err := decodeLanePacket(packet)
			if err != nil {
				t.Fatal(err)
			}
			if d.kind == laneTypeRepair && d.esi == 2 && d.count == laneRepairWindow {
				return
			}
			windows = append(windows, fmt.Sprintf("type %d [%d, +%d)", d.kind, d.esi, d.count))
		}
		t.Fatalf("the timer at %d ms sent %v; want a repair over the oldest window [2, +64)", now, windows)
	}
	t.Fatal("the timer never fired")
}

// THE 64 kbit/s BUDGET CAPS PROACTIVE REPAIR, however much the loss rate asks for.
func TestTheBudgetCapsProactiveRepair(t *testing.T) {
	e := newLaneEngine(13, 0)
	e.receive(encodeLaneFeedback(0, 0, laneFeedback{lossPermille: 500}), 0) // r = 50%: a repair every 2 symbols
	proactive := 0
	for now := int64(1); now <= 2000; now++ {
		if err := e.send(0, bytes.Repeat([]byte{7}, 1000)); err != nil {
			t.Fatal(err)
		}
		for _, packet := range e.poll(now, laneQueueTarget) {
			if packet[0] == laneTypeRepair {
				proactive += len(packet)
			}
		}
		// Everything acknowledged at once, so no repair is a GAP repair.
		ack := laneFeedback{cumESI: uint32(e.nextESI), lossPermille: 500, echoTS: uint32(now)}
		e.receive(encodeLaneFeedback(uint32(now), uint32(now), ack), now)
	}
	limit := laneBudgetBurst + laneBudgetBytesPerMs*2000 + lanePacketMax
	if proactive > limit {
		t.Fatalf("%d bytes of proactive repair in 2 s; the budget allows %d", proactive, limit)
	}
	if proactive < limit/2 {
		t.Fatalf("only %d bytes of repair: the test never reached the budget", proactive)
	}
}

// PAST 512 UNACKNOWLEDGED SYMBOLS THE STREAMS REPORT FULL, AND DRAIN AS ACKNOWLEDGEMENTS COME — nothing dropped or
// reordered (a full re-send of every tab is bigger than the window).
func TestPastTheHeldWindowTheStreamsReportFull(t *testing.T) {
	p := newLanePipe(t, 17, 0)
	p.delay = 40
	p.loss = [2]float64{0, 1} // no acknowledgement reaches a
	var want laneWant
	for i := 0; i < 600; i++ {
		want[0][0] = append(want[0][0], laneTestMessage(0, i, 1000))
	}
	p.sendAll(want)
	p.runUntil(func() bool { return p.now >= 500 }, 500)
	sources := 0
	for _, s := range p.sent[0] {
		if s.packet[0] == laneTypeSource {
			sources++
		}
	}
	if sources != laneHeldMax {
		t.Fatalf("%d symbols sent with nothing acknowledged; the window is %d", sources, laneHeldMax)
	}
	// Nothing acknowledged: the stream reports everything handed (600 KB), not only what is not yet in a symbol.
	if got := p.engines[0].buffered(0); got != 600*1000 {
		t.Fatalf("past the window with nothing acknowledged the stream reports %d; want the 600000 handed", got)
	}
	p.loss = [2]float64{0, 0}
	p.runUntil(func() bool { return p.delivered(want) }, 60_000)
	p.assertDelivered(want)
}

// THE QUEUE TARGET FOLLOWS THE DELIVERY RATE AT THE BASE ROUND TRIP: pion counts unacknowledged bytes as buffered, so
// a fixed ceiling would cap the lane at 16 KB a round trip — and a target sized from srtt sized itself: srtt carries
// pion's queue, which the target holds (measured: srtt 11 s, the target 11 MB). The base is the least pristine sample
// — a packet sent into a lane holding nothing else unacknowledged.
func TestTheQueueTargetFollowsTheDeliveryRateAtTheBaseRoundTrip(t *testing.T) {
	e := newLaneEngine(43, 0)
	if got := e.queueTarget(0); got != laneQueueTarget {
		t.Fatalf("an idle lane's target is %d, want %d", got, laneQueueTarget)
	}
	// A lone symbol, acknowledged 20 ms later: the base round trip is 20 ms.
	if err := e.send(2, []byte("a keystroke's echo")); err != nil {
		t.Fatal(err)
	}
	e.poll(0, 1<<30)
	e.receive(encodeLaneFeedback(0, 20, laneFeedback{cumESI: uint32(e.nextESI), echoTS: 0}), 20)
	if !e.hasBase || e.baseRTT != 20 {
		t.Fatalf("base round trip %v (known %v), want 20", e.baseRTT, e.hasBase)
	}
	// A 100 KB burst at t=1000, acknowledged whole at t=1500: a 500 ms sample that is pion's queue, not the path.
	for i := 0; i < 100; i++ {
		if err := e.send(0, make([]byte, 1000)); err != nil {
			t.Fatal(err)
		}
	}
	e.poll(1000, 1<<30)
	e.receive(encodeLaneFeedback(1, 1500, laneFeedback{cumESI: uint32(e.nextESI), echoTS: 1000}), 1500)
	if e.baseRTT != 20 {
		t.Fatalf("a burst's acknowledgement moved the base to %v", e.baseRTT)
	}
	if e.srtt < 60 {
		t.Fatalf("srtt %v did not take the burst's 500 ms sample", e.srtt)
	}
	// ~100 KB/s over the last second, at a 20 ms base: 2 × 100 KB/s × 20 ms = ~4 KB over the floor — not ~10 KB (srtt).
	got := e.queueTarget(1510)
	if least, most := laneQueueTarget+2*90*20, laneQueueTarget+2*110*20; got < least || got > most {
		t.Fatalf("target %d after ~100 KB/s at a 20 ms base; want %d–%d", got, least, most)
	}
	if got := e.queueTarget(1510 + laneRateBuckets*laneRateBucketMs); got != laneQueueTarget {
		t.Fatalf("target %d a second later; the rate must age out", got)
	}
}

// BEFORE A PRISTINE SAMPLE THE TARGET USES THE INITIAL TIMER, NOT SRTT: a lane that opens into a burst never sends a
// lone packet, its srtt is the queue's (1.2 s after a blackout, measured), and a target sized from it asked for 967 KB.
func TestTheQueueTargetNeverFallsBackToSrtt(t *testing.T) {
	e := newLaneEngine(43, 0)
	for i := 0; i < 100; i++ {
		if err := e.send(0, make([]byte, 1000)); err != nil {
			t.Fatal(err)
		}
	}
	e.poll(0, 1<<30) // ~100 symbols in one poll: nothing pristine
	e.receive(encodeLaneFeedback(0, 500, laneFeedback{cumESI: uint32(e.nextESI), echoTS: 0}), 500)
	if e.hasBase {
		t.Fatal("a burst's acknowledgement must not be a base sample")
	}
	if e.srtt < 400 {
		t.Fatalf("srtt %v did not take the 500 ms sample", e.srtt)
	}
	// ~100 KB/s over the last second at the 200 ms initial timer: ≤ 16 KB + 2 × 110 KB/s × 200 ms — not ~116 KB (srtt).
	if got, most := e.queueTarget(510), laneQueueTarget+2*110*laneTimerInitialMs; got > most {
		t.Fatalf("target %d with no base known; want at most %d (srtt would give ~%d)", got, most, laneQueueTarget+2*100*500)
	}
}

// THE BASE ROUND TRIP'S RULES, each one: a sample is pristine only when its poll sent ≤ 2 packets and left ≤ 1 symbol
// unacknowledged; a second's samples keep their least; a sample ages out of the 10 s window; with the window empty the
// last base stands. web/test/lane.test.ts runs the same cases.
func TestTheBaseRoundTripsRules(t *testing.T) {
	ack := func(e *laneEngine, pkt uint32, now int64, echoTS uint32) {
		e.receive(encodeLaneFeedback(pkt, uint32(now), laneFeedback{cumESI: uint32(e.nextESI), echoTS: echoTS}), now)
	}
	t.Run("a lone symbol is pristine; a symbol beside a feedback is too", func(t *testing.T) {
		e := newLaneEngine(1, 0)
		if err := e.send(2, []byte("lone")); err != nil {
			t.Fatal(err)
		}
		if n := len(e.poll(0, 1<<30)); n != 1 {
			t.Fatalf("%d packets, want the lone symbol", n)
		}
		ack(e, 0, 30, 0)
		if !e.hasBase || e.baseRTT != 30 {
			t.Fatalf("base %v (known %v), want 30 from the lone symbol", e.baseRTT, e.hasBase)
		}
		// The peer's own data makes this end owe feedback; the next poll sends that feedback AND a symbol: two packets.
		e.receive(encodeLaneSource(1, 100, 0, buildLaneSymbol([]laneChunk{{2, 0, []byte{0, 0, 0, 1, 'x'}}})), 100)
		if err := e.send(2, []byte("second")); err != nil {
			t.Fatal(err)
		}
		packets := e.poll(120, 1<<30)
		if len(packets) != 2 {
			t.Fatalf("%d packets, want a feedback and a symbol", len(packets))
		}
		ack(e, 2, 140, 120)
		if e.baseRTT != 20 {
			t.Fatalf("base %v, want 20: a symbol beside a feedback is pristine", e.baseRTT)
		}
	})
	t.Run("a burst is not pristine, nor a poll that leaves two symbols unacknowledged", func(t *testing.T) {
		e := newLaneEngine(1, 0)
		for i := 0; i < 3; i++ {
			if err := e.send(0, make([]byte, 1000)); err != nil {
				t.Fatal(err)
			}
		}
		e.poll(0, 1<<30) // three symbols
		ack(e, 0, 30, 0)
		if e.hasBase {
			t.Fatal("a three-symbol poll must not give a base")
		}
		if err := e.send(0, make([]byte, 1500)); err != nil { // two symbols, one message
			t.Fatal(err)
		}
		if n := len(e.poll(100, 1<<30)); n != 2 {
			t.Fatalf("%d packets, want two symbols", n)
		}
		ack(e, 1, 130, 100)
		if e.hasBase {
			t.Fatal("a poll leaving two symbols unacknowledged must not give a base")
		}
	})
	t.Run("a second keeps its least sample; the window ages out; the last base stands", func(t *testing.T) {
		e := newLaneEngine(1, 0)
		lone := func(now int64, rtt int64, pkt uint32) {
			if err := e.send(2, []byte("k")); err != nil {
				t.Fatal(err)
			}
			e.poll(now, 1<<30)
			ack(e, pkt, now+rtt, uint32(now))
		}
		lone(0, 10, 0)
		lone(200, 40, 1) // the same second: the least stands, not the last
		if e.baseRTT != 10 {
			t.Fatalf("base %v, want the second's least, 10", e.baseRTT)
		}
		lone(3000, 25, 2)
		if e.baseRTT != 10 {
			t.Fatalf("base %v, want 10 while the 10 ms sample is in the window", e.baseRTT)
		}
		lone(11_500, 25, 3) // second 11: second 0's sample has aged out (> 10 s), second 3's has not
		if e.baseRTT != 25 {
			t.Fatalf("base %v, want 25 once the 10 ms sample aged out", e.baseRTT)
		}
		// 30 s of burst: no pristine sample, the last base stands (never zero for lack of samples).
		for i := 0; i < 50; i++ {
			if err := e.send(0, make([]byte, 1000)); err != nil {
				t.Fatal(err)
			}
		}
		e.poll(12_000, 1<<30)
		ack(e, 4, 42_000, 12_000)
		if !e.hasBase || e.baseRTT != 25 {
			t.Fatalf("base %v (known %v), want the last base, 25, to stand", e.baseRTT, e.hasBase)
		}
	})
}

// A PACKET NO NEWER THAN THE NEWEST SEEN MEASURES NOTHING. The carrier is reliable, so SCTP's late copy of a packet
// the lane counted lost — or a reorder — arrives after newer ones: it must not cancel the loss (the estimate is of
// loss on FIRST transmission, what the lane's repair faces), and the echo must time the NEWEST packet, or the sender's
// round trip takes SCTP's retransmission delay. lane.test.ts runs the same case.
func TestALateCopyMovesNeitherTheLossWindowNorTheEcho(t *testing.T) {
	e := newLaneEngine(61, 0)
	source := func(pkt, ts uint32, esi int) []byte {
		chunk := laneChunk{2, uint32(esi * 5), []byte{0, 0, 0, 1, byte('a' + esi)}}
		return encodeLaneSource(pkt, ts, uint32(esi), buildLaneSymbol([]laneChunk{chunk}))
	}
	feedback := func(now int64) laneFeedback {
		t.Helper()
		for _, packet := range e.poll(now, 1<<30) {
			if p, err := decodeLanePacket(packet); err == nil && p.kind == laneTypeFeedback {
				return p.feedback
			}
		}
		t.Fatalf("no feedback at %d ms", now)
		return laneFeedback{}
	}
	e.receive(source(0, 10, 0), 100)
	e.receive(source(2, 30, 2), 120) // packet 1 (ESI 1) lost on its first transmission
	first := feedback(120)
	if first.echoTS != 30 || first.lossPermille != 333 {
		t.Fatalf("precondition: the feedback after the gap echoes ts %d with loss %d‰; want 30 and 333‰",
			first.echoTS, first.lossPermille)
	}
	e.receive(source(1, 20, 1), 400) // SCTP's late copy of packet 1
	second := feedback(420)
	if second.cumESI != 3 {
		t.Fatalf("the late copy's symbol was not used: cumESI %d, want 3", second.cumESI)
	}
	if second.echoTS != 30 || second.held != 300 {
		t.Errorf("the feedback after the late copy echoes ts %d held %d ms; want packet 2's: ts 30, held 300 — a "+
			"late copy's echo adds SCTP's retransmission delay to the sender's round trip", second.echoTS, second.held)
	}
	if second.lossPermille != 333 {
		t.Errorf("the late copy cancelled the loss: %d‰, want 333‰ — the estimate is of loss on first "+
			"transmission, what the lane's repair faces", second.lossPermille)
	}
}

// ...AND A LATE FEEDBACK GIVES NO ROUND-TRIP SAMPLE: SCTP's late copy of a feedback the peer sent before its newest
// packet echoes a packet this end sent long before, so its sample is the retransmission delay, not the path. Its
// acknowledgement still counts. lane.test.ts runs the same case.
func TestALateFeedbackGivesNoRoundTripSample(t *testing.T) {
	e := newLaneEngine(62, 0)
	for i := 0; i < 2; i++ {
		if err := e.send(2, []byte{byte('a' + i)}); err != nil {
			t.Fatal(err)
		}
		e.poll(int64(i), 1<<30) // ESIs 0 and 1, sent at 0 and 1 ms
	}
	e.receive(encodeLaneFeedback(3, 30, laneFeedback{cumESI: 1, echoTS: 0}), 30)
	if e.srtt != 30 {
		t.Fatalf("precondition: srtt %v, want 30", e.srtt)
	}
	e.receive(encodeLaneSource(5, 40, 0, buildLaneSymbol([]laneChunk{{2, 0, []byte{0, 0, 0, 1, 'x'}}})), 40)
	// The peer's packet 4, a feedback sent between those two, arrives late: it acknowledges ESI 1, echoing ts 1.
	e.receive(encodeLaneFeedback(4, 31, laneFeedback{cumESI: 2, echoTS: 1}), 500)
	if e.srtt != 30 {
		t.Fatalf("srtt %v: a late feedback's 499 ms sample is SCTP's retransmission delay, not the round trip", e.srtt)
	}
	if e.heldFrom != 2 {
		t.Fatalf("the late feedback's acknowledgement was dropped: heldFrom %d, want 2", e.heldFrom)
	}
}

// ...AND A LATE FEEDBACK APPLIES ONLY ITS CUMULATIVE ACKNOWLEDGEMENT. One no newer than the newest FEEDBACK seen
// (here the peer's packet 5 after its packet 6) describes the receiver as it was: its loss, its ranges and the gap
// repairs they would plan must leave the newer report standing — whatever it says. What it acknowledges cumulatively
// is still acknowledged. lane.test.ts runs the same case.
func TestALateFeedbackAppliesOnlyItsCumulativeAcknowledgement(t *testing.T) {
	e := newLaneEngine(63, 0)
	for i := 0; i < 10; i++ {
		if err := e.send(2, []byte{byte(i)}); err != nil {
			t.Fatal(err)
		}
		e.poll(int64(i), laneQueueTarget) // one symbol each: ESIs 0..9 at 0..9 ms
	}
	e.poll(19, laneQueueTarget) // the tail repair goes; nothing else is owed
	// The newest feedback: 0..2 decoded, nothing above, no loss, echoing the packet sent at 9 ms — nothing missing.
	e.receive(encodeLaneFeedback(6, 39, laneFeedback{cumESI: 3, echoTS: 9}), 40)
	if packets := e.poll(40, laneQueueTarget); len(packets) != 0 {
		t.Fatalf("precondition: the newest feedback shows nothing missing, yet %d packets went", len(packets))
	}
	// Its packet 5 arrives late: 3 decoded too, a hole at 4..7 under 8..9, 40% loss.
	e.receive(encodeLaneFeedback(5, 38, laneFeedback{cumESI: 4, ranges: []laneRange{{8, 2}}, lossPermille: 400, echoTS: 9}), 41)
	if e.heldFrom != 4 {
		t.Errorf("the late feedback's cumulative acknowledgement was dropped: heldFrom %d, want 4", e.heldFrom)
	}
	if e.lossPermille != 0 {
		t.Errorf("the late feedback's %d‰ overwrote the newest feedback's 0‰", e.lossPermille)
	}
	if len(e.knownAbove) != 0 {
		t.Errorf("the late feedback rebuilt the ranges known above the acknowledgement: %v", e.knownAbove)
	}
	if packets := e.poll(41, laneQueueTarget); len(packets) != 0 {
		t.Errorf("the late feedback's stale holes drew %d gap repairs", len(packets))
	}
}

// A LATE-FILLED HOLE RELEASES EVERYTHING ABOVE IT IN ONE FEEDBACK — 160 KB at once after a 10 s stall on a 12.5 KB/s
// link (measured). The rate is the bytes acknowledged over the last SECOND, so that lump reads as 160 KB/s, not the
// 1.6 MB/s a best-100-ms bucket made of it (which raised the target by 64 KB: 5 s of link).
func TestALumpOfAcknowledgementsDoesNotBlowUpTheQueueTarget(t *testing.T) {
	e := newLaneEngine(43, 0)
	if err := e.send(2, []byte("x")); err != nil {
		t.Fatal(err)
	}
	e.poll(0, 1<<30)
	e.receive(encodeLaneFeedback(0, 20, laneFeedback{cumESI: uint32(e.nextESI), echoTS: 0}), 20) // base 20 ms
	for i := 0; i < 160; i++ {
		if err := e.send(0, make([]byte, 1000)); err != nil {
			t.Fatal(err)
		}
	}
	e.poll(1000, 1<<30)
	e.receive(encodeLaneFeedback(1, 11_000, laneFeedback{cumESI: uint32(e.nextESI), echoTS: 1000}), 11_000)
	if got, most := e.queueTarget(11_010), laneQueueTarget+2*170*20; got > most {
		t.Fatalf("target %d after a 160 KB lump; want at most %d", got, most)
	}
}

func TestAStuckLaneIsDeclaredAfter30s(t *testing.T) {
	e := newLaneEngine(19, 0)
	if err := e.send(1, []byte("k")); err != nil {
		t.Fatal(err)
	}
	e.poll(0, laneQueueTarget)
	if e.stuck(laneStuckMs - 1) {
		t.Fatal("stuck before 30 s")
	}
	if !e.stuck(laneStuckMs) {
		t.Fatal("not stuck after 30 s holding data with no feedback")
	}
	e.resetStuck(laneStuckMs) // the connection came back: the clock starts over
	if e.stuck(2*laneStuckMs-1) || !e.stuck(2*laneStuckMs) {
		t.Fatal("resetStuck did not restart the 30 s")
	}
	r := newLaneEngine(23, 0)
	r.receive(encodeLaneSource(0, 0, 1, buildLaneSymbol([]laneChunk{{1, 0, []byte{0, 0, 0, 1, 'k'}}})), 0) // ESI 0 never comes
	if r.stuck(laneStuckMs-1) || !r.stuck(laneStuckMs) {
		t.Fatal("a receiver with a hole it cannot fill must be stuck at 30 s, not before")
	}
}

// STUCK MEANS NO PROGRESS, NOT NO FEEDBACK (stalledFor): the peer's keepalive feedback, acknowledging nothing new,
// kept a lane whose own packets never arrived alive forever (2026-10-13: a phone's keystrokes held in its SCTP's
// backoff, the Mac's packets still getting through — typing with no reply, neither end ever stuck). A feedback that
// moves the cumulative acknowledgement IS progress.
func TestStuckMeansNoProgressNotNoFeedback(t *testing.T) {
	e := newLaneEngine(19, 0)
	if err := e.send(1, []byte("k")); err != nil {
		t.Fatal(err)
	}
	e.poll(0, laneQueueTarget)
	if got := e.stalledFor(1000); got != 1000 {
		t.Fatalf("stalledFor after 1 s holding: %d", got)
	}
	for at := int64(1000); at < laneStuckMs; at += 1000 { // the peer's keepalive, every second, acknowledging nothing
		e.receive(encodeLaneFeedback(uint32(at/1000), uint32(at), laneFeedback{cumESI: 0}), at)
	}
	if !e.stuck(laneStuckMs) {
		t.Fatal("feedback that acknowledges nothing kept the lane from being stuck")
	}
	e.receive(encodeLaneFeedback(100, laneStuckMs, laneFeedback{cumESI: 1}), laneStuckMs) // ESI 0 acknowledged
	if e.stuck(laneStuckMs+1) || e.stalledFor(laneStuckMs+1) != -1 {
		t.Fatal("an acknowledgement is progress: nothing is held, nothing is stuck")
	}
}

// THE RECEIVER'S 30 s IS FOR A HOLE IT CANNOT FILL, not for some hole at every arrival: under sustained output on a
// lossy path the oldest hole keeps filling while a newer one opens above it — a lane that works.
func TestAHoleThatKeepsFillingIsNotStuck(t *testing.T) {
	r := newLaneEngine(55, 0)
	empty := buildLaneSymbol(nil)
	pkt := uint32(0)
	arrive := func(esi uint32, now int64) {
		r.receive(encodeLaneSource(pkt, uint32(now), esi, empty), now)
		pkt++
		if r.cumESI > r.highestESI {
			t.Fatalf("precondition: no hole at %d ms", now)
		}
	}
	arrive(1, 0) // a hole at 0
	var now int64
	for i := int64(1); i <= 2*laneStuckMs/1000; i++ { // a second apart, for twice the threshold
		now = i * 1000
		arrive(uint32(2*i+1), now) // a new hole opens at 2i…
		arrive(uint32(2*i-2), now) // …and the oldest, 2i − 2, fills: cumESI moves on to 2i
		if r.stuck(now) {
			t.Fatalf("stuck at %d ms, though every hole so far filled within a second", now)
		}
	}
	// And a hole that stops filling, while data keeps arriving above it, is stuck 30 s after cumESI last moved.
	last := now
	for esi := uint32(2*(now/1000) + 3); now < last+laneStuckMs; esi++ {
		now += 1000
		arrive(esi, now)
		if r.stuck(now-1) != (now-1-last >= laneStuckMs) {
			t.Fatalf("at %d ms stuck = %v; the hole has not filled since %d ms", now-1, r.stuck(now-1), last)
		}
	}
	if !r.stuck(now) {
		t.Fatalf("not stuck at %d ms, %d ms after the hole last filled", now, now-last)
	}
}

// A PEER THAT BREAKS THE PROTOCOL CLOSES THE LANE, AND GROWS NOTHING (Important 4 of the final review): none of
// these is reachable from a conforming peer, but the Mac's engine runs in the user's app. A chunk further ahead of the
// delivered offset than the sender's window could carry would sit in `segments` forever — cumESI still advances, so
// nothing else ever notices — and a frame header claiming more than a message would grow `framed` to 4 GiB.
// lane.test.ts runs the same cases.
func TestAChunkPastTheSendersWindowClosesTheLane(t *testing.T) {
	r := newLaneEngine(65, 0)
	bound := uint32(laneHeldMax * laneSymbolMax)
	r.receive(encodeLaneSource(0, 0, 0, buildLaneSymbol([]laneChunk{{0, bound, []byte{1}}})), 0)
	if r.stuck(0) || len(r.in[0].segments) != 1 {
		t.Fatalf("a chunk at the window's reach is a conforming sender's: stuck %v, %d kept (want false, 1)", r.stuck(0), len(r.in[0].segments))
	}
	r.receive(encodeLaneSource(1, 1, 1, buildLaneSymbol([]laneChunk{{0, bound + 1, []byte{2}}})), 1)
	if !r.stuck(1) {
		t.Error("a chunk past what the sender's window could hold did not close the lane")
	}
	if len(r.in[0].segments) != 1 {
		t.Errorf("a chunk past what the sender's window could hold was kept: %d segments", len(r.in[0].segments))
	}
}

func TestAFrameLongerThanAnyMessageClosesTheLane(t *testing.T) {
	frame := func(size uint32) []byte {
		return encodeLaneSource(0, 0, 0, buildLaneSymbol([]laneChunk{{2, 0, binary.BigEndian.AppendUint32(nil, size)}}))
	}
	r := newLaneEngine(66, 0)
	r.receive(frame(laneMessageMax), 0)
	if r.stuck(0) {
		t.Fatal("a frame of exactly 1 MiB is a message, waiting for its bytes")
	}
	r = newLaneEngine(67, 0)
	r.receive(frame(laneMessageMax+1), 0)
	if !r.stuck(0) {
		t.Error("a frame claiming more than 1 MiB did not close the lane")
	}
}

// AN ESI PAST WHAT THE SENDER'S WINDOW COULD HOLD IS REFUSED: it would lift highestESI by up to 2³¹, and every feedback
// after would walk cumESI…highestESI under the lane's lock — a multi-second stall of pion's read goroutine per feedback.
func TestAnESIPastTheSendersWindowIsRefused(t *testing.T) {
	r := newLaneEngine(68, 0)
	empty := buildLaneSymbol(nil)
	r.receive(encodeLaneSource(0, 0, laneDecoderHistory-1, empty), 0)
	if r.highestESI != laneDecoderHistory-1 {
		t.Fatalf("precondition: a source within the decoder's history is taken; highestESI %d", r.highestESI)
	}
	r.receive(encodeLaneSource(1, 0, laneDecoderHistory, empty), 0)
	if r.highestESI != laneDecoderHistory-1 {
		t.Errorf("a source at cumESI + %d moved highestESI to %d", laneDecoderHistory, r.highestESI)
	}
	r.receive(encodeLaneRepair(2, 0, laneDecoderHistory-1, 2, 1, make([]byte, 2)), 0)
	r.receive(encodeLaneRepair(3, 0, 1<<31, 1, 1, make([]byte, 2)), 0)
	if r.highestESI != laneDecoderHistory-1 {
		t.Errorf("a repair reaching past cumESI + %d moved highestESI to %d", laneDecoderHistory, r.highestESI)
	}
}

// A SYMBOL THE ENGINE CANNOT USE LEAVES ITS HOLE: one that does not parse, or a known ESI whose symbol the decoder no
// longer holds, must not be acknowledged — marked processed first, cumESI moved past bytes no stream was given and
// that stream froze silently (the page's engine threw instead). The hole stays, and at 30 s the lane is stuck.
func TestASymbolTheEngineCannotUseLeavesItsHole(t *testing.T) {
	r := newLaneEngine(69, 0)
	r.receive(encodeLaneSource(0, 0, 0, []byte{0xff, 0xff}), 0) // a length no symbol has
	if r.cumESI != 0 {
		t.Errorf("a symbol that does not parse was acknowledged: cumESI %d, want 0", r.cumESI)
	}
	if !r.stuck(laneStuckMs) {
		t.Error("the hole a malformed symbol leaves must be stuck at 30 s")
	}
	r = newLaneEngine(70, 0)
	r.noteData(0, 0, []uint64{0}) // known, yet the decoder does not hold it
	if r.cumESI != 0 {
		t.Errorf("a symbol the decoder does not hold was acknowledged: cumESI %d, want 0", r.cumESI)
	}
}

func TestTheCountersWrap(t *testing.T) {
	p := newLanePipe(t, 29, 1<<32-40)
	p.loss, p.delay = [2]float64{0.05, 0.05}, 20
	var want laneWant
	for i := 0; i < 200; i++ {
		want[0][0] = append(want[0][0], laneTestMessage(0, i, 1500))
	}
	for i := 0; i < 50; i++ {
		want[1][1] = append(want[1][1], laneTestMessage(1, i, 38))
	}
	p.sendAll(want)
	p.runUntil(func() bool { return p.delivered(want) }, 60_000)
	p.assertDelivered(want)
}

func TestTheLaneRefusesEmptyAndOversizeMessagesAndCarriesOneMiB(t *testing.T) {
	e := newLaneEngine(31, 0)
	if e.send(0, nil) == nil {
		t.Fatal("an empty message was accepted (pion refuses an empty send too)")
	}
	if e.send(0, make([]byte, laneMessageMax+1)) == nil {
		t.Fatal("a message over 1 MiB was accepted")
	}
	p := newLanePipe(t, 37, 0)
	p.loss, p.delay = [2]float64{0.05, 0.05}, 20
	var want laneWant
	want[0][2] = [][]byte{laneTestMessage(2, 0, laneMessageMax)}
	p.sendAll(want)
	p.runUntil(func() bool { return p.delivered(want) }, 60_000)
	p.assertDelivered(want)
}

// REVIEW FOCUS 1: a receiver that polls only when a packet arrives (its timers throttled) still acknowledges what
// arrives — the sender's timer repairs and its keepalive draw feedback — so the sender is never stuck.
func TestAReceiverPolledOnlyOnArrivalStillAcknowledges(t *testing.T) {
	p := newLanePipe(t, 41, 0)
	p.loss, p.delay = [2]float64{0.05, 0.05}, 40
	p.pollOnArrivalOnly[1] = true
	var want laneWant
	for i := 0; i < 200; i++ {
		want[0][0] = append(want[0][0], laneTestMessage(0, i, 700))
	}
	p.sendAll(want)
	p.runUntil(func() bool { return p.delivered(want) }, 120_000)
	p.assertDelivered(want)
	a := p.engines[0]
	p.runUntil(func() bool { return a.nextESI == a.heldFrom }, p.now+10_000)
	if a.nextESI != a.heldFrom {
		t.Fatalf("a still holds %d unacknowledged symbols 10 s after delivery", a.nextESI-a.heldFrom)
	}
	if a.stuck(p.now) {
		t.Fatal("the sender was declared stuck")
	}
}

// A STREAM'S BUFFERED AMOUNT IS WHAT THE PEER HAS NOT ACKNOWLEDGED, IN PAYLOAD BYTES: TermPacer's model of the number
// (pion's bufferedAmount counts bytes until SCTP acknowledges them). Not the bytes not yet in a symbol — those read 0
// whenever the lane had room, and the pacer handed a whole re-send into the stream's FIFO; and not the framed bytes —
// 4 more per message, so `handed − buffered` stepped back by 4 per message and TermPath's rate wrapped.
func TestAStreamsBufferedAmountIsWhatThePeerHasNotAcknowledged(t *testing.T) {
	e := newLaneEngine(5, 0)
	for _, size := range []int{10, 20, 30} {
		if err := e.send(0, make([]byte, size)); err != nil {
			t.Fatal(err)
		}
	}
	if got := e.buffered(0); got != 60 {
		t.Fatalf("three pending messages of 60 payload bytes read %d (72 would be the framed bytes)", got)
	}
	if n := len(e.poll(0, 1<<30)); n != 1 {
		t.Fatalf("one symbol expected, %d packets sent", n)
	}
	if got := e.buffered(0); got != 60 {
		t.Fatalf("in a symbol and unacknowledged, the stream still holds 60; read %d", got)
	}
	e.receive(encodeLaneFeedback(0, 10, laneFeedback{cumESI: uint32(e.nextESI), echoTS: 0}), 10)
	if got := e.buffered(0); got != 0 {
		t.Fatalf("acknowledged, the stream holds nothing; read %d", got)
	}
}

// `handed − buffered` NEVER DECREASES: acknowledgements arrive by symbol, a symbol boundary falls anywhere in a
// message — inside a 1-byte message's 4-byte prefix too — and a step back wraps TermPath's rate (the host crashed on
// the Int conversion). Checked after every step of a lossy run of messages of every size.
func TestHandedMinusBufferedNeverDecreases(t *testing.T) {
	p := newLanePipe(t, 23, 0)
	p.loss, p.delay = [2]float64{0.1, 0.1}, 30
	var want laneWant
	handed := 0
	for i := 0; i < 400; i++ {
		size := 1 + (i*37)%1500
		if i%7 == 0 {
			size = 1
		}
		want[0][0] = append(want[0][0], laneTestMessage(0, i, size))
	}
	p.sendAll(want)
	for _, m := range want[0][0] {
		handed += len(m)
	}
	least := -1
	a := p.engines[0]
	// Through delivery, then on until the last acknowledgement is back (a one-way delay after the last delivery).
	for p.now < 60_000 && (!p.delivered(want) || a.nextESI > a.heldFrom) {
		p.step()
		acked := handed - a.buffered(0)
		if acked < least {
			t.Fatalf("at %d ms handed − buffered fell from %d to %d", p.now, least, acked)
		}
		least = acked
	}
	p.assertDelivered(want)
	if got := a.buffered(0); got != 0 || a.nextESI > a.heldFrom {
		t.Fatalf("everything delivered and acknowledged (%d unacknowledged symbols), yet the stream reads %d", a.nextESI-a.heldFrom, got)
	}
}

// THE TWO ENGINES ARE ONE BEHAVIOUR: each scenario of protocol/fixtures/lane-parity.json — loss, bursts, reordering,
// duplicates, late copies, a stretch at zero room, both directions, counters at the wrap — run over the pipe, every
// packet each side emits hashed in order, against the digests lane.test.ts asserts too. The byte-level vectors pin the
// encodings; only this catches a feedback-timing or repair-planning rule changed on one side. A digest that moves is
// pasted in from this failure's message, and lane.test.ts must then pass unchanged.
type laneParityFile struct {
	CheckpointEvery int                  `json:"checkpointEvery"`
	Scenarios       []laneParityScenario `json:"scenarios"`
}

type laneParityScenario struct {
	Name      string     `json:"name"`
	Seed      int64      `json:"seed"`
	Initial   uint64     `json:"initial"`
	Delay     int64      `json:"delay"`
	Loss      [2]float64 `json:"loss"`
	Burst     float64    `json:"burst"`
	Reorder   float64    `json:"reorder"`
	Duplicate float64    `json:"duplicate"`
	Late      int64      `json:"late"`
	ZeroRoom  []struct {
		Side int   `json:"side"`
		From int64 `json:"from"`
		To   int64 `json:"to"`
	} `json:"zeroRoom"`
	Traffic []struct {
		Side   int    `json:"side"`
		Stream int    `json:"stream"`
		Count  int    `json:"count"`
		Size   [3]int `json:"size"` // base, mul, mod: message i is base + (i·mul) mod `mod` bytes
		At     int64  `json:"at"`
		Every  int64  `json:"every"`
	} `json:"traffic"`
	End   int64             `json:"end"`
	Sides [2]laneParitySide `json:"sides"`
}

type laneParitySide struct {
	Packets     int      `json:"packets"`
	SHA256      string   `json:"sha256"`
	Checkpoints []string `json:"checkpoints"`
}

func (s laneParityScenario) run(t *testing.T, checkpointEvery int) [2]laneParitySide {
	t.Helper()
	p := newLanePipe(t, s.Seed, s.Initial)
	p.delay, p.loss, p.burst, p.reorder, p.duplicate, p.late = s.Delay, s.Loss, s.Burst, s.Reorder, s.Duplicate, s.Late
	if len(s.ZeroRoom) > 0 {
		p.room = func(side int, now int64) int {
			for _, z := range s.ZeroRoom {
				if z.Side == side && now >= z.From && now < z.To {
					return 0
				}
			}
			return laneQueueTarget
		}
	}
	var want laneWant
	sent := make([]int, len(s.Traffic))
	for p.now < s.End {
		for k, tr := range s.Traffic {
			for ; sent[k] < tr.Count && tr.At+int64(sent[k])*tr.Every <= p.now; sent[k]++ {
				m := laneTestMessage(tr.Stream, sent[k], tr.Size[0]+(sent[k]*tr.Size[1])%tr.Size[2])
				if err := p.engines[tr.Side].send(tr.Stream, m); err != nil {
					t.Fatalf("send: %v", err)
				}
				want[tr.Side][tr.Stream] = append(want[tr.Side][tr.Stream], m)
			}
		}
		p.step()
	}
	for k, tr := range s.Traffic {
		if sent[k] != tr.Count {
			t.Fatalf("traffic %d: %d of %d messages sent by the end: the scenario must send everything", k, sent[k], tr.Count)
		}
	}
	p.assertDelivered(want) // a digest of a run that failed to deliver would pin a broken behaviour
	var out [2]laneParitySide
	for side := range out {
		h := sha256.New()
		out[side].Checkpoints = []string{}
		for i, l := range p.sent[side] {
			var head [7]byte
			binary.BigEndian.PutUint32(head[0:], uint32(l.at))
			if l.lost {
				head[4] = 1
			}
			binary.BigEndian.PutUint16(head[5:], uint16(len(l.packet)))
			h.Write(head[:])
			h.Write(l.packet)
			if (i+1)%checkpointEvery == 0 {
				out[side].Checkpoints = append(out[side].Checkpoints, hex.EncodeToString(h.Sum(nil))[:16])
			}
		}
		out[side].Packets, out[side].SHA256 = len(p.sent[side]), hex.EncodeToString(h.Sum(nil))
	}
	return out
}

func TestTheEnginesAgreePacketForPacket(t *testing.T) {
	raw, err := os.ReadFile("../../../protocol/fixtures/lane-parity.json")
	if err != nil {
		t.Fatalf("read the lane parity fixture: %v", err)
	}
	var f laneParityFile
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatalf("parse the lane parity fixture: %v", err)
	}
	if len(f.Scenarios) == 0 || f.CheckpointEvery <= 0 {
		t.Fatal("the parity fixture holds no scenario: an empty list passes every assertion")
	}
	for _, s := range f.Scenarios {
		t.Run(s.Name, func(t *testing.T) {
			got := s.run(t, f.CheckpointEvery)
			for side := range got {
				if got[side].Packets == 0 {
					t.Fatalf("side %d sent nothing", side)
				}
			}
			if fmt.Sprint(got) == fmt.Sprint(s.Sides) {
				return
			}
			for side := range got {
				w, g := s.Sides[side], got[side]
				for i := 0; i < min(len(w.Checkpoints), len(g.Checkpoints)); i++ {
					if w.Checkpoints[i] != g.Checkpoints[i] {
						t.Errorf("side %d first differs within packets [%d, %d)", side, i*f.CheckpointEvery, (i+1)*f.CheckpointEvery)
						break
					}
				}
			}
			block, _ := json.Marshal(got)
			t.Fatalf("the packets differ from the fixture's digests; if the engine change is meant, paste this as the "+
				"scenario's \"sides\" and lane.test.ts must then pass unchanged:\n%s", block)
		})
	}
}
