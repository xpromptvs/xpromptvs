package main

import (
	"encoding/binary"
	"io"
	"maps"
	"net"
	"slices"
	"sync"
	"testing"
	"time"

	"github.com/pion/sctp"
)

// pion/sctp, as third_party/pion-sctp/abandon-on-loss.patch makes it, abandons a never-retransmitted chunk (the ?dc=1
// `video` channel's {ordered: false, maxRetransmits: 0}, or any other such channel's) where it would RETRANSMIT it —
// once loss detection says it is lost — never at its first transmission. Stock v1.10.0 marked it abandoned as it was
// sent, so every SACK that arrived while it was still in flight advanced the Advanced.Peer.Ack.Point and drew a
// FORWARD-TSN (RFC 3758 C3): one FORWARD-TSN, and the browser's SACK of it, per packet with nothing lost. (The
// terminal lane, which first showed it, is reliable now: never retransmitted, it let the browser's own SCTP storm
// FORWARD-TSN on a slow link.) These tests watch the wire between two real associations: the first FAILS on the stock
// module; the other two each fail when one of the patch's two abandon sites is removed.

const (
	abandonOneWayDelay = 20 * time.Millisecond // > the send gap, so every SACK arrives with newer chunks in flight
	abandonSendGap     = 5 * time.Millisecond
	abandonMessages    = 50
	abandonMessageSize = 100
	abandonSettle      = 5 * time.Second
	abandonReleaseGap  = 2 * time.Millisecond // between a packet and each one held back for it: separate SACKs
	// The most FORWARD-TSNs one lost chunk may draw. Patched, each SACK of the round trip before the first lands
	// repeats it: 8–9 measured, up to 13 with the fast-retransmit run's reordered chunks. Stock draws one on nearly
	// every SACK of the run: ~50.
	abandonForwardTSNsPerLoss = abandonMessages / 2

	abandonClientToServer = 0
	abandonServerToClient = 1

	sctpChunkData         = 0
	sctpChunkSack         = 3
	sctpChunkIData        = 64
	sctpChunkForwardTSN   = 192
	sctpChunkIForwardTSN  = 194
	sctpCommonHeaderBytes = 12
)

// abandonRun is what a run does to the client's DATA chunks, counted 1-based in the order sent.
type abandonRun struct {
	dropNth   int         // drop the packet carrying this DATA chunk on its first transmission; 0 = none
	holdUntil map[int]int // deliver the packet carrying DATA chunk n only after the one carrying chunk holdUntil[n]
	client    []sctp.ClientOption
}

// abandonWire is the link between the two associations: a fixed one-way delay each way, every SCTP packet seen in
// PLAINTEXT as it is written (no DTLS here), chosen DATA packets dropped or delivered late.
type abandonWire struct {
	mu      sync.Mutex
	changed chan struct{} // poked after every packet and every message read
	run     abandonRun
	seen    abandonSeen
}

// abandonSeen is what crossed the wire.
type abandonSeen struct {
	sawData        bool
	firstTSN       uint32
	highestTSN     uint32
	sent           map[uint32]int // client→server DATA transmissions, per TSN
	iData          int
	forwardTSNs    [2][]uint32 // per direction: each FORWARD-TSN's new cumulative TSN
	sawSack        bool
	sackCum        uint32 // the latest server→client SACK's cumulative TSN ack
	sacksBehind    int    // server→client SACKs written while a newer DATA chunk was already on its way
	droppedTSN     uint32
	droppedIndices map[uint16]bool // the messages the dropped packet carried
	received       map[uint16]int  // message index → times the server read it
}

func newAbandonWire(run abandonRun) *abandonWire {
	return &abandonWire{
		changed: make(chan struct{}, 1),
		run:     run,
		seen:    abandonSeen{sent: map[uint32]int{}, droppedIndices: map[uint16]bool{}, received: map[uint16]int{}},
	}
}

func (w *abandonWire) poke() {
	select {
	case w.changed <- struct{}{}:
	default:
	}
}

func tsnAtLeast(a, b uint32) bool { return int32(a-b) >= 0 }

// observe parses a packet as it is written — the common header, then chunks `type u8 · flags u8 · length u16`
// padded to 4 — and says whether to drop it, which chunk's packet to hold it back for (0: none), and which DATA
// chunks it carries.
func (w *abandonWire) observe(dir int, p []byte) (drop bool, holdFor int, nths []int) {
	w.mu.Lock()
	defer w.mu.Unlock()
	defer w.poke()
	seen := &w.seen

	var tsns []uint32
	var indices []uint16
	for off := sctpCommonHeaderBytes; off+4 <= len(p); {
		length := int(binary.BigEndian.Uint16(p[off+2:]))
		if length < 4 || off+length > len(p) {
			break
		}
		switch p[off] {
		case sctpChunkData:
			if dir == abandonClientToServer && length >= 18 { // 16-byte DATA header, then the message's index
				tsns = append(tsns, binary.BigEndian.Uint32(p[off+4:]))
				indices = append(indices, binary.BigEndian.Uint16(p[off+16:]))
			}
		case sctpChunkIData:
			seen.iData++
		case sctpChunkForwardTSN, sctpChunkIForwardTSN:
			if length >= 8 {
				seen.forwardTSNs[dir] = append(seen.forwardTSNs[dir], binary.BigEndian.Uint32(p[off+4:]))
			}
		case sctpChunkSack:
			if dir == abandonServerToClient && length >= 8 {
				seen.sackCum, seen.sawSack = binary.BigEndian.Uint32(p[off+4:]), true
				if seen.sawData && !tsnAtLeast(seen.sackCum, seen.highestTSN) {
					seen.sacksBehind++
				}
			}
		}
		off += (length + 3) &^ 3
	}

	for _, tsn := range tsns {
		if !seen.sawData {
			seen.firstTSN, seen.highestTSN, seen.sawData = tsn, tsn, true
		}
		nth := int(tsn-seen.firstTSN) + 1
		if nth == w.run.dropNth && seen.sent[tsn] == 0 {
			drop = true
			seen.droppedTSN = tsn
			for _, index := range indices {
				seen.droppedIndices[index] = true
			}
		}
		if afterNth, ok := w.run.holdUntil[nth]; ok && seen.sent[tsn] == 0 && holdFor == 0 {
			holdFor = afterNth
		}
		nths = append(nths, nth)
	}
	for _, tsn := range tsns {
		seen.sent[tsn]++
		if tsnAtLeast(tsn, seen.highestTSN) {
			seen.highestTSN = tsn
		}
	}

	if drop {
		holdFor = 0
	}
	return drop, holdFor, nths
}

func (w *abandonWire) read(index uint16) {
	w.mu.Lock()
	w.seen.received[index]++
	w.mu.Unlock()
	w.poke()
}

// settled: every message is on the wire, every one not dropped has been read, and the receiver has acknowledged
// the newest TSN — after which nothing is in flight, so nothing more can be retransmitted or skipped.
func (w *abandonWire) settled() bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	seen := &w.seen
	if len(seen.sent) < abandonMessages || !seen.sawSack || !tsnAtLeast(seen.sackCum, seen.highestTSN) {
		return false
	}
	for index := range uint16(abandonMessages) {
		if !seen.droppedIndices[index] && seen.received[index] == 0 {
			return false
		}
	}
	return true
}

func (w *abandonWire) snapshot() abandonSeen {
	w.mu.Lock()
	defer w.mu.Unlock()
	seen := w.seen
	seen.sent, seen.droppedIndices, seen.received = maps.Clone(seen.sent), maps.Clone(seen.droppedIndices),
		maps.Clone(seen.received)
	for dir := range seen.forwardTSNs {
		seen.forwardTSNs[dir] = append([]uint32(nil), seen.forwardTSNs[dir]...)
	}
	return seen
}

type abandonPacket struct {
	b   []byte
	due time.Time
}

// abandonEnd is one end of the wire, as the net.Conn an association runs over.
type abandonEnd struct {
	wire      *abandonWire
	dir       int
	in        chan abandonPacket
	peer      *abandonEnd
	closed    chan struct{}
	closeOnce sync.Once
	mu        sync.Mutex
	held      []abandonHeld
	written   int // the newest DATA chunk written through this end, held, dropped or forwarded
}

type abandonHeld struct {
	b     []byte
	nths  []int // the DATA chunks it carries
	after int   // released once the packet carrying this DATA chunk has gone
}

func newAbandonEnds(wire *abandonWire) (client, server *abandonEnd) {
	end := func(dir int) *abandonEnd {
		return &abandonEnd{wire: wire, dir: dir, in: make(chan abandonPacket, 1024), closed: make(chan struct{})}
	}
	client, server = end(abandonClientToServer), end(abandonServerToClient)
	client.peer, server.peer = server, client
	return client, server
}

func (e *abandonEnd) Write(p []byte) (int, error) {
	select {
	case <-e.closed:
		return 0, net.ErrClosed
	default:
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	drop, holdFor, nths := e.wire.observe(e.dir, p)
	packet := append([]byte(nil), p...)
	hold := holdFor > 0 && e.mayHold(holdFor, nths)
	for _, nth := range nths {
		e.written = max(e.written, nth)
	}
	switch {
	case drop:
		if err := e.release(nths, 0); err != nil { // what waited for it waits no more
			return 0, err
		}
	case hold:
		e.held = append(e.held, abandonHeld{b: packet, nths: nths, after: holdFor})
	default:
		if err := e.forward(packet, nths, 0); err != nil {
			return 0, err
		}
	}
	return len(p), nil
}

// mayHold: a packet is held back for chunk `after` only if that chunk is still to come or is itself held, never for
// one it carries or one already gone; and only if no packet already held waits for a chunk it carries. Otherwise a
// bundle — {4,5} or {3,4,5} in one packet — would leave holds waiting on each other, and the run would hang to its
// settle bound. Such a packet goes at once. The caller holds e.mu.
func (e *abandonEnd) mayHold(after int, nths []int) bool {
	if slices.Contains(nths, after) {
		return false
	}
	coming := after > e.written
	for _, held := range e.held {
		if slices.Contains(nths, held.after) {
			return false
		}
		coming = coming || slices.Contains(held.nths, after)
	}
	return coming
}

// forward sends a packet, then — abandonReleaseGap apart, so the receiver answers each with its own SACK — every
// packet held back for a chunk it carries. The caller holds e.mu.
func (e *abandonEnd) forward(b []byte, nths []int, lag time.Duration) error {
	if err := e.send(b, lag); err != nil {
		return err
	}
	return e.release(nths, lag)
}

// release forwards every packet held back for one of these chunks. The caller holds e.mu.
func (e *abandonEnd) release(nths []int, lag time.Duration) error {
	for _, nth := range nths {
		for i := 0; i < len(e.held); i++ {
			if held := e.held[i]; held.after == nth {
				e.held = append(e.held[:i], e.held[i+1:]...)
				lag += abandonReleaseGap
				if err := e.forward(held.b, held.nths, lag); err != nil {
					return err
				}
				i = -1 // the slice changed under the recursion: rescan
			}
		}
	}
	return nil
}

// stillHeld lists the DATA chunks of every packet still held back.
func (e *abandonEnd) stillHeld() [][]int {
	e.mu.Lock()
	defer e.mu.Unlock()
	var chunks [][]int
	for _, held := range e.held {
		chunks = append(chunks, held.nths)
	}
	return chunks
}

func (e *abandonEnd) send(b []byte, lag time.Duration) error {
	select {
	case e.peer.in <- abandonPacket{b: b, due: time.Now().Add(abandonOneWayDelay + lag)}:
	case <-e.peer.closed:
	case <-e.closed:
		return net.ErrClosed
	}
	return nil
}

func (e *abandonEnd) Read(p []byte) (int, error) {
	select {
	case packet := <-e.in:
		if wait := time.Until(packet.due); wait > 0 {
			timer := time.NewTimer(wait)
			select {
			case <-timer.C:
			case <-e.closed:
				timer.Stop()
				return 0, io.EOF
			}
		}
		return copy(p, packet.b), nil
	case <-e.closed:
		return 0, io.EOF
	}
}

func (e *abandonEnd) Close() error {
	e.closeOnce.Do(func() { close(e.closed) })
	return nil
}

type abandonAddr struct{}

func (abandonAddr) Network() string { return "abandon-wire" }
func (abandonAddr) String() string  { return "abandon-wire" }

func (e *abandonEnd) LocalAddr() net.Addr              { return abandonAddr{} }
func (e *abandonEnd) RemoteAddr() net.Addr             { return abandonAddr{} }
func (e *abandonEnd) SetDeadline(time.Time) error      { return nil }
func (e *abandonEnd) SetReadDeadline(time.Time) error  { return nil }
func (e *abandonEnd) SetWriteDeadline(time.Time) error { return nil }

// sendNeverRetransmitted sends abandonMessages paced messages on a stream configured as the lane is — unordered,
// rexmit policy, 0 retransmissions — and returns what crossed the wire once it has settled.
func sendNeverRetransmitted(t *testing.T, run abandonRun) abandonSeen {
	t.Helper()
	wire := newAbandonWire(run)
	clientEnd, serverEnd := newAbandonEnds(wire)

	// Interleaving OFF on both ends, as against Chrome: DATA (0) and FORWARD-TSN (192). Two pion ends would
	// otherwise negotiate I-DATA and I-FORWARD-TSN (v1.10.0 defaults it on).
	type accepted struct {
		assoc *sctp.Association
		err   error
	}
	serverCh := make(chan accepted, 1)
	go func() {
		assoc, err := sctp.ServerWithOptions(sctp.WithNetConn(serverEnd), sctp.WithEnableInterleaving(false))
		serverCh <- accepted{assoc, err}
	}()
	client, err := sctp.ClientWithOptions(append([]sctp.ClientOption{sctp.WithNetConn(clientEnd),
		sctp.WithEnableInterleaving(false)}, run.client...)...)
	if err != nil {
		_ = serverEnd.Close()
		t.Fatalf("sctp client: %v", err)
	}
	srv := <-serverCh
	if srv.err != nil {
		_ = client.Close()
		t.Fatalf("sctp server: %v", srv.err)
	}
	server := srv.assoc

	readerDone := make(chan struct{})
	t.Cleanup(func() {
		_ = client.Close()
		_ = server.Close()
		<-readerDone
	})
	go func() {
		defer close(readerDone)
		stream, err := server.AcceptStream()
		if err != nil {
			return
		}
		buf := make([]byte, 2048)
		for {
			n, err := stream.Read(buf)
			if err != nil {
				return
			}
			if n >= 2 {
				wire.read(binary.BigEndian.Uint16(buf))
			}
		}
	}()

	stream, err := client.OpenStream(1, sctp.PayloadTypeWebRTCBinary)
	if err != nil {
		t.Fatalf("OpenStream: %v", err)
	}
	stream.SetReliabilityParams(true, sctp.ReliabilityTypeRexmit, 0)

	pace := time.NewTicker(abandonSendGap)
	defer pace.Stop()
	message := make([]byte, abandonMessageSize)
	for index := range uint16(abandonMessages) {
		binary.BigEndian.PutUint16(message, index)
		if _, err := stream.Write(message); err != nil {
			t.Fatalf("write %d: %v", index, err)
		}
		<-pace.C
	}

	deadline := time.NewTimer(abandonSettle)
	defer deadline.Stop()
	for !wire.settled() {
		select {
		case <-wire.changed:
		case <-deadline.C:
			seen := wire.snapshot()
			t.Fatalf("not settled within %v: %d of %d DATA chunks on the wire, %d messages read, SACK cum %d "+
				"(seen %v), newest TSN %d, %d FORWARD-TSN, packets still held back (their DATA chunks): %v",
				abandonSettle, len(seen.sent), abandonMessages, len(seen.received), seen.sackCum, seen.sawSack,
				seen.highestTSN, len(seen.forwardTSNs[abandonClientToServer]), clientEnd.stillHeld())
		}
	}

	seen := wire.snapshot()
	if seen.iData > 0 || !seen.sawData {
		t.Fatalf("the wire carried %d I-DATA chunks and DATA=%v; the parser reads DATA (type 0)",
			seen.iData, seen.sawData)
	}
	for tsn, times := range seen.sent {
		if times != 1 {
			t.Errorf("TSN %d (DATA chunk %d of the run) was transmitted %d times; a chunk with 0 retransmissions "+
				"goes once", tsn, tsn-seen.firstTSN+1, times)
		}
	}
	return seen
}

// Nothing lost ⇒ nothing abandoned ⇒ no FORWARD-TSN, either way. Stock pion sends one on nearly every SACK here.
func TestANeverRetransmittedChunkThatArrivesDrawsNoForwardTSN(t *testing.T) {
	seen := sendNeverRetransmitted(t, abandonRun{})
	// The condition the storm needs: SACKs that arrive with newer chunks in flight. Without it, zero proves nothing.
	if seen.sacksBehind < abandonMessages/5 {
		t.Fatalf("only %d SACKs were sent with newer DATA in flight; the link must hold several chunks in flight",
			seen.sacksBehind)
	}
	for dir, name := range []string{"client→server", "server→client"} {
		if n := len(seen.forwardTSNs[dir]); n != 0 {
			t.Errorf("%s carried %d FORWARD-TSN chunks for %d messages (%d SACKs behind) with nothing lost; want "+
				"0 — a chunk abandoned while in flight draws one on every SACK (RFC 3758 C3). Stock pion/sctp? The "+
				"patch is applied only under Bazel: third_party/pion-sctp/abandon-on-loss.patch",
				name, n, abandonMessages, seen.sacksBehind)
		}
	}
	t.Logf("%d SACKs sent with newer DATA in flight; FORWARD-TSNs: %d client→server, %d server→client",
		seen.sacksBehind, len(seen.forwardTSNs[abandonClientToServer]), len(seen.forwardTSNs[abandonServerToClient]))
}

// One chunk lost ⇒ a FORWARD-TSN skips it, and it is never sent again; every other message arrives once. On this
// FIFO link RACK declares the loss (one SACK past the hole), so the chunk is abandoned in getDataPacketsToRetransmit.
func TestANeverRetransmittedChunkThatIsLostIsSkippedNotRetransmitted(t *testing.T) {
	assertSkippedNotRetransmitted(t, sendNeverRetransmitted(t, abandonRun{dropNth: 10}))
}

// The same when FAST RETRANSMIT declares the loss — the patch's other site. RACK holds its reordering window at 0
// until it has seen a reordering — a SACK that newly acks only chunks older than one already acked — so chunks 3
// and 4 arrive after 5 (3 while 4 is still missing, so its SACK is immediate and acks 3 alone), and a window floor
// of 7 send gaps (under the SRTT that bounds it) lets three gap reports come before RACK would mark chunk 10.
// (RACK, its window still 0, declares 3 and 4 lost at 5's SACK; they reach the receiver before their FORWARD-TSN.)
// Mutation-checked: without the abandon in gatherOutboundFastRetransmissionPackets this run fast-retransmits the
// chunk; the run above does not.
func TestANeverRetransmittedChunkThatFastRetransmitDeclaresLostIsSkippedToo(t *testing.T) {
	assertSkippedNotRetransmitted(t, sendNeverRetransmitted(t, abandonRun{
		dropNth:   10,
		holdUntil: map[int]int{3: 5, 4: 3},
		client:    []sctp.ClientOption{sctp.WithRACKOptions(sctp.WithRackReoWndFloor(7 * abandonSendGap))},
	}))
}

func assertSkippedNotRetransmitted(t *testing.T, seen abandonSeen) {
	t.Helper()
	if len(seen.droppedIndices) == 0 {
		t.Fatalf("the wire dropped nothing")
	}
	if got := seen.sent[seen.droppedTSN]; got != 1 {
		t.Errorf("the dropped TSN %d was transmitted %d times; want 1", seen.droppedTSN, got)
	}
	covered := false
	for _, cum := range seen.forwardTSNs[abandonClientToServer] {
		covered = covered || tsnAtLeast(cum, seen.droppedTSN)
	}
	if !covered {
		t.Errorf("no FORWARD-TSN covered the dropped TSN %d (sent: %v)", seen.droppedTSN,
			seen.forwardTSNs[abandonClientToServer])
	}
	if n := len(seen.forwardTSNs[abandonClientToServer]); n >= abandonForwardTSNsPerLoss {
		t.Errorf("%d FORWARD-TSN chunks for one lost chunk in %d messages; want < %d — stock pion/sctp abandons "+
			"every chunk at send (the patch is applied only under Bazel: third_party/pion-sctp/abandon-on-loss.patch)",
			n, abandonMessages, abandonForwardTSNsPerLoss)
	}
	if want := abandonMessages - len(seen.droppedIndices); len(seen.received) != want {
		t.Errorf("%d messages read; want %d (all but the %d the dropped packet carried)",
			len(seen.received), want, len(seen.droppedIndices))
	}
	for index, times := range seen.received {
		if times != 1 || seen.droppedIndices[index] {
			t.Errorf("message %d read %d times (dropped: %v)", index, times, seen.droppedIndices[index])
		}
	}
	t.Logf("dropped TSN %d (message(s) %v); FORWARD-TSNs: %d", seen.droppedTSN, seen.droppedIndices,
		len(seen.forwardTSNs[abandonClientToServer]))
}
