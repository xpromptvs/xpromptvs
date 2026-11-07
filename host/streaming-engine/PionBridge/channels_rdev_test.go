package main

// The offer path's DataChannels: rdev's three, and what readiness now means.
//
// Every test here drives the OFFER path. The answering path's channels are LLV's and are
// covered by channels_test.go and the startSessionPair suites, unchanged — the two paths do
// opposite things with channels, so they are asserted separately rather than through one
// abstraction that would have to be true of both.

import (
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/pion/webrtc/v4"
)

// rdev's control channel carries JSON, sent as TEXT — which is what the web client does
// (`channel.send(JSON.stringify(message))`). That is why this is the payload used below and why
// it is sent with SendText: LLV's validateChannelMessage refuses a text message outright, before
// it even looks at the bytes, so routing the offer path's inbound messages back through LLV's
// validator fails the session instead of delivering. Measured, not assumed — the falsification
// produced `DataChannel policy violation: text message`.
const testRdevControlPayload = `{"t":"list-sources"}`

// THE TEST THIS TASK EXISTS FOR. maybeReady returns SILENTLY on any unmet precondition, two of
// which are "input open" and "control open" — so a channel set swapped without rewiring what
// those terms are set FROM produces a session that negotiates, connects, and then simply never
// becomes ready, with nothing anywhere reporting why.
//
// It asserts both halves: that the three channels reach the REMOTE (not merely that
// CreateDataChannel returned), and that readiness is reached with them.
func TestOfferSessionCreatesRdevChannelsAndBecomesReady(t *testing.T) {
	pair := newTestOfferPair(t)
	if err := pair.session.SetAnswer(pair.answer); err != nil {
		t.Fatalf("SetAnswer: %v", err)
	}
	for _, label := range []string{"terminal", "input", "control"} {
		pair.awaitRemoteChannel(t, label)
	}
	// A PER-SOURCE TRACK IS NOW PART OF REACHING READY, and that is the point of the eager track's
	// removal rather than an inconvenience: readiness is no longer a proxy for "the channels are
	// up". The channel half is what this test is about and is asserted above by label; the track is
	// added here so that readiness is REACHABLE at all, and if the channel terms were wired wrong
	// the timeout below still names them.
	if _, err := pair.session.AddVideoTrack("win:channels"); err != nil {
		t.Fatalf("AddVideoTrack: %v", err)
	}
	pair.renegotiate(t)
	// WaitReady rather than a bare <-readyCh: it reports which preconditions were still unmet,
	// which is the difference between "this is the channel gate" and "something, somewhere, did
	// not happen".
	if err := pair.session.WaitReady(15 * time.Second); err != nil {
		t.Fatal(err)
	}
}

// The offer path creates EXACTLY these three and nothing else — in particular neither of LLV's.
// Asserted separately from the test above, because "the three rdev channels arrived" stays true
// of a session that also offers two more, and a session speaking both protocols at once is
// exactly the half-migration this task must not leave behind.
//
// TWO THINGS THIS IS CAREFUL ABOUT, both learned by making it fail on purpose.
//
//   - It reads the session's own channel map, NOT the answerer's, because the remote side cannot
//     answer "and no others" without a race: a fourth channel created before the offer still
//     arrives at the answerer whenever SCTP gets to it, so a snapshot taken once the third has
//     landed can miss it. Measured — with an LLV channel added to the created set, the answerer
//     had seen exactly the three rdev ones 20 ms in. Reachability is test 1's job, and it proves
//     it per label rather than by counting.
//   - The expectation is a LITERAL list, not len(rdevChannelLabels). Comparing the created set
//     against the constant it was built from is not a check; it is a restatement, and it passes
//     for any set whatsoever.
func TestOfferSessionOffersNoLLVChannels(t *testing.T) {
	pair := newTestOfferPair(t)
	wanted := map[string]bool{"terminal": true, "input": true, "control": true, "bulk": true}

	pair.session.mutex.Lock()
	created := make([]string, 0, len(pair.session.rdevChannels))
	for label, channel := range pair.session.rdevChannels {
		// The map key is ours; the label is pion's own record of what it put in the SDP.
		created = append(created, channel.Label())
		if label != channel.Label() {
			t.Errorf("channel filed under %q reports label %q", label, channel.Label())
		}
	}
	pair.session.mutex.Unlock()
	sort.Strings(created)

	if len(created) != len(wanted) {
		t.Fatalf("the offer path created %v, want exactly terminal, input, control and bulk", created)
	}
	for _, label := range created {
		if !wanted[label] {
			t.Fatalf("the offer path created %v, which includes the unexpected %q", created, label)
		}
	}
}

// Inbound payloads surface through the per-label callback, unexamined. The payload is JSON,
// which LLV's wire validator would reject — so this fails if the offer path is ever wired
// through validateChannelMessage, and not merely if the callback is missing.
func TestOfferSessionSurfacesInboundPayloadsByLabel(t *testing.T) {
	pair := newTestOfferPair(t)
	if err := pair.session.SetAnswer(pair.answer); err != nil {
		t.Fatalf("SetAnswer: %v", err)
	}
	control := pair.awaitRemoteChannel(t, rdevControlChannelLabel)
	// NOT WaitReady, WHICH THIS USED TO USE AS A PROXY FOR "the session's end opened". Readiness
	// now also requires a bound video track, so waiting on it here would make a test about channel
	// payloads depend on a subscription it does not make. The open notification is the exact
	// signal, and it exists now.
	awaitChannelOpen(t, pair, rdevControlChannelLabel)
	// The remote's copy has to be open before it can send; the open above says the SESSION's
	// end opened, which is a different end of the same channel.
	deadline := time.Now().Add(10 * time.Second)
	for control.ReadyState() != webrtc.DataChannelStateOpen {
		if time.Now().After(deadline) {
			t.Fatalf("the answerer's control channel never opened (state %s)", control.ReadyState())
		}
		time.Sleep(10 * time.Millisecond)
	}
	if err := control.SendText(testRdevControlPayload); err != nil {
		t.Fatalf("answerer send on control: %v", err)
	}
	select {
	case message := <-pair.inbound:
		if message.label != rdevControlChannelLabel {
			t.Fatalf("inbound payload arrived on label %q, want %q",
				message.label, rdevControlChannelLabel)
		}
		if string(message.data) != testRdevControlPayload {
			t.Fatalf("inbound payload = %q, want %q", message.data, testRdevControlPayload)
		}
	case <-pair.session.failedCh:
		pair.session.mutex.Lock()
		failure := pair.session.failure
		pair.session.mutex.Unlock()
		t.Fatalf("the session failed instead of delivering an rdev payload: %v", failure)
	case <-time.After(10 * time.Second):
		t.Fatal("no inbound payload reached OnChannelMessage")
	}
}

// TERMINAL IS DELIBERATELY UNGATED, and this is where that decision lives as a checkable fact.
// The OnOpen handler in createRdevDataChannels consults rdevReadinessTerm and does nothing else,
// so adding the terminal to the readiness gate means changing this function and failing here.
//
// WHAT IT CANNOT SEE: someone adding a separate `terminalOpen` term to readinessBlockersLocked
// directly, bypassing this mapping entirely. No unit test can prevent that; the reason it must
// not happen is written on rdevReadinessTerm and on readinessBlockersLocked.
func TestTerminalDoesNotGateReadiness(t *testing.T) {
	if _, gates := rdevReadinessTerm(rdevTerminalChannelLabel); gates {
		t.Fatal("the terminal channel gates readiness — a PTY problem can now present as the engine failing to start")
	}
	for label, wanted := range map[string]ChannelKind{
		rdevInputChannelLabel:   ChannelInput,
		rdevControlChannelLabel: ChannelControl,
	} {
		term, gates := rdevReadinessTerm(label)
		if !gates || term != wanted {
			t.Fatalf("rdevReadinessTerm(%q) = (%v, %v), want (%v, true)", label, term, gates, wanted)
		}
	}
}

// The readiness timeout names what it was waiting on. Without it, a channel that never opened,
// ICE that never connected, a track that never bound and signalling that never finished are one
// indistinguishable sentence — which is how a session that never becomes ready costs a bisect
// instead of a glance.
func TestReadinessTimeoutNamesWhatItIsWaitingOn(t *testing.T) {
	session := newTestOfferSession(t, SessionCallbacks{OnLocalICECandidate: func(string) {}})
	err := session.WaitReady(10 * time.Millisecond)
	if err == nil {
		t.Fatal("a session that never signalled reported ready")
	}
	for _, wanted := range []string{
		"signalling incomplete", "video track not bound", "PeerConnection not connected",
		"input DataChannel not open", "control DataChannel not open",
	} {
		if !strings.Contains(err.Error(), wanted) {
			t.Fatalf("readiness timeout = %q, want it to name %q", err, wanted)
		}
	}
}

// A blocker list that is EMPTY has to say so in words. "still waiting on:" with nothing after the
// colon names no cause, which is the silent gate this mechanism exists to expose in a different
// costume — and it is reachable two ways: readiness landing in the window after the select
// committed to the timeout, or every precondition being met while nothing called maybeReady
// afterwards. The second is a real bug that is invisible from every individual condition.
//
// Driven by setting the preconditions DIRECTLY rather than through the peer, because that is the
// only way to reach "all met, not ready" deterministically: going through the real path would call
// maybeReady and close readyCh, which is the case this test is not about.
func TestReadinessTimeoutSaysSoWhenNothingIsUnmet(t *testing.T) {
	session := newTestOfferSession(t, SessionCallbacks{OnLocalICECandidate: func(string) {}})
	session.mutex.Lock()
	session.signalingComplete = true
	session.mediaReady = true
	session.peerConnected = true
	session.inputOpen = true
	session.controlOpen = true
	blockers := session.readinessBlockersLocked()
	session.mutex.Unlock()
	// Guards the setup rather than the behaviour: if a new precondition is added and not set
	// here, the test below would pass for the wrong reason — a non-empty list formatted normally.
	if len(blockers) != 0 {
		t.Fatalf("test setup leaves %v unmet, so the empty-list branch is not what is reached", blockers)
	}

	err := session.WaitReady(10 * time.Millisecond)
	if err == nil {
		t.Fatal("a session whose readyCh never closed reported ready")
	}
	if strings.Contains(err.Error(), "still waiting on:") {
		t.Fatalf("readiness timeout = %q, which names nothing after the colon", err)
	}
	if !strings.Contains(err.Error(), "no unmet precondition") {
		t.Fatalf("readiness timeout = %q, want it to say that nothing was left unmet", err)
	}
}

// markChannelOpen is now ONE shared helper reached from both channel sets, where it used to be two
// inline copies each behind a gate that could only produce two values. An unrecognised kind must
// therefore not fall through to control: that would satisfy a readiness term from the wrong
// channel, which is this task's failure class rather than a typo. Unreachable through either
// production path — which is exactly why it needs a test to stay true.
func TestMarkChannelOpenFailsOnAnUnrecognisedKind(t *testing.T) {
	session := newTestOfferSession(t, SessionCallbacks{OnLocalICECandidate: func(string) {}})
	session.markChannelOpen(ChannelKind(99))

	select {
	case <-session.failedCh:
	case <-time.After(2 * time.Second):
		t.Fatal("an unrecognised channel kind was accepted")
	}
	session.mutex.Lock()
	failure, inputOpen, controlOpen := session.failure, session.inputOpen, session.controlOpen
	session.mutex.Unlock()
	if failure == nil || !strings.Contains(failure.Error(), "unrecognised channel kind 99") {
		t.Fatalf("failure = %v, want it to name the unrecognised kind", failure)
	}
	// The point of the finding: falling through would have set controlOpen. Asserted directly,
	// because "the session failed" is also true of an implementation that failed AND set it.
	if inputOpen || controlOpen {
		t.Fatalf("an unrecognised kind set a readiness term: input %v, control %v", inputOpen, controlOpen)
	}
}

// An offer session that silently discards inbound payloads comes up healthy, negotiates,
// reports ready — and then never streams anything, because rdev's client drives every subscribe
// over `control` and nothing was listening. Refused at construction, like the ICE callback.
func TestOfferSessionRequiresAChannelMessageCallback(t *testing.T) {
	_, err := newOfferSession(testOfferConfiguration(t), SessionCallbacks{
		OnLocalICECandidate: func(string) {},
	})
	if err == nil {
		t.Fatal("an offer session without a channel message callback was accepted")
	}
	if !strings.Contains(err.Error(), "channel message") {
		t.Fatalf("error = %q, want it to name the missing callback", err)
	}
}

// EVERY CREATED CHANNEL REPORTS ITS OPEN, INCLUDING `terminal`, and the terminal is the whole
// reason this callback is not simply readiness in another costume. rdev's ChannelHub spawns the
// first shell on `terminal`'s open and pushes control-state, the tab list and the view set on
// `control`'s — so a notification wired only to the two channels that gate readiness would leave a
// connected session with a permanently blank terminal and every other signal healthy.
//
// The labels are collected and SORTED rather than compared in arrival order: SCTP decides which of
// three simultaneously-created channels opens first, so an ordered expectation would be asserting
// the transport's scheduling.
func TestOfferSessionReportsEveryChannelOpenByLabel(t *testing.T) {
	pair := newTestOfferPair(t)
	if err := pair.session.SetAnswer(pair.answer); err != nil {
		t.Fatalf("SetAnswer: %v", err)
	}
	seen := map[string]bool{}
	deadline := time.After(15 * time.Second)
	for len(seen) < len(rdevChannelLabels) {
		select {
		case label := <-pair.opens:
			seen[label] = true
		case <-deadline:
			t.Fatalf("only %v reported open, want all of %v", sortedKeys(seen), rdevChannelLabels)
		}
	}
	got := sortedKeys(seen)
	want := []string{"bulk", "control", "input", "terminal"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("channels reported open = %v, want %v", got, want)
	}
}

// An offer session that never reports a channel open connects, negotiates and then does nothing:
// rdev's host starts no shell, sends no control-state and pushes no view set, because all three are
// driven off an open. Refused at construction, like the ICE and message callbacks.
func TestOfferSessionRequiresAChannelOpenCallback(t *testing.T) {
	_, err := newOfferSession(testOfferConfiguration(t), SessionCallbacks{
		OnLocalICECandidate: func(string) {},
		OnChannelMessage:    func(string, []byte) {},
	})
	if err == nil {
		t.Fatal("an offer session without a channel open callback was accepted")
	}
	if !strings.Contains(err.Error(), "channel open") {
		t.Fatalf("error = %q, want it to name the missing callback", err)
	}
}

// THE OUTBOUND HALF, AND IT IS THE ONE WITH NO OTHER COVERAGE. Every other test here drives
// payloads INTO the session; rdev's host is a sender on all three of these channels — terminal
// output, cursor shapes, view sets — and SendInput/SendControl cannot serve it, because they
// validate their argument as an LLV1 frame, which no rdev payload is.
//
// The assertion is that the bytes reach the REMOTE, not that Send returned nil: a payload written
// to a channel the answerer never sees is the shape of failure this project keeps meeting.
func TestSendChannelDataReachesTheRemoteByLabel(t *testing.T) {
	pair := newTestOfferPair(t)
	if err := pair.session.SetAnswer(pair.answer); err != nil {
		t.Fatalf("SetAnswer: %v", err)
	}
	terminal := pair.awaitRemoteChannel(t, rdevTerminalChannelLabel)
	received := make(chan []byte, 4)
	terminal.OnMessage(func(message webrtc.DataChannelMessage) {
		received <- append([]byte(nil), message.Data...)
	})
	// `terminal` FIRST, deliberately: this session has no video track, so it can never be READY —
	// which is exactly the state a real rdev host is in before a client subscribes, and exactly when
	// it must already be able to write terminal output and read `control`. A SendChannelData that
	// required readiness would deadlock there, and asserting through a channel with no readiness
	// term is what makes this test able to see it.
	payload := []byte{0x00, 0x1b, 0x5b, 0x41, 0xff}
	if err := waitSendChannelData(pair.session, rdevTerminalChannelLabel, payload); err != nil {
		t.Fatalf("SendChannelData on terminal: %v", err)
	}
	select {
	case got := <-received:
		if string(got) != string(payload) {
			t.Fatalf("remote received %v, want %v", got, payload)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the payload never reached the answerer's terminal channel")
	}

	// RAW BYTES, NOT AN LLV1 FRAME, on the channel LLV's own SendControl would police. This is what
	// pins "unexamined": SendControl(payload) would refuse this with a policy violation.
	control := pair.awaitRemoteChannel(t, rdevControlChannelLabel)
	controlReceived := make(chan []byte, 4)
	control.OnMessage(func(message webrtc.DataChannelMessage) {
		controlReceived <- append([]byte(nil), message.Data...)
	})
	json := []byte(testRdevControlPayload)
	if err := waitSendChannelData(pair.session, rdevControlChannelLabel, json); err != nil {
		t.Fatalf("SendChannelData on control: %v", err)
	}
	if err := pair.session.SendControl(json); err == nil {
		t.Fatal("SendControl accepted an rdev JSON payload; it must only carry LLV1 frames")
	}
	select {
	case got := <-controlReceived:
		if string(got) != testRdevControlPayload {
			t.Fatalf("remote received %q, want %q", got, testRdevControlPayload)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the JSON payload never reached the answerer's control channel")
	}
}

// A send to a label this session does not have is an ERROR, not a silent drop. rdev's own bridge
// dropped (`if dc := p.chans[ch]; dc != nil`), and CLAUDE.md records what that cost: a dead control
// channel presenting as an app that had simply stopped responding, with the footer still reporting a
// live connection.
func TestSendChannelDataRefusesAnUnknownLabel(t *testing.T) {
	pair := newTestOfferPair(t)
	if err := pair.session.SetAnswer(pair.answer); err != nil {
		t.Fatalf("SetAnswer: %v", err)
	}
	err := pair.session.SendChannelData("llv-control-v1", []byte("x"))
	if err == nil {
		t.Fatal("a send to a label this session never created was accepted")
	}
	// LLV's label is used as the unknown one on purpose: it is the label a half-migrated caller
	// would reach for, so the message has to name what was asked for rather than say "unknown".
	if !strings.Contains(err.Error(), "llv-control-v1") {
		t.Fatalf("error = %q, want it to name the label", err)
	}
	if err := pair.session.SendChannelData(rdevControlChannelLabel, nil); err == nil {
		t.Fatal("an empty payload was accepted")
	}
}

// What a sender paces on (FileFetcher, an image on `control`): an open channel's unsent bytes, and
// NOT OPEN for a label this session lacks — a pacing loop stops on it rather than waiting forever.
func TestChannelBufferedAmountIsAnOpenChannelsUnsentBytes(t *testing.T) {
	pair := newTestOfferPair(t)
	if _, open := pair.session.ChannelBufferedAmount(rdevControlChannelLabel); open {
		t.Fatal("a channel before the answer reads as open")
	}
	if err := pair.session.SetAnswer(pair.answer); err != nil {
		t.Fatalf("SetAnswer: %v", err)
	}
	pair.awaitRemoteChannel(t, rdevControlChannelLabel)
	if err := waitSendChannelData(pair.session, rdevControlChannelLabel, []byte(testRdevControlPayload)); err != nil {
		t.Fatalf("SendChannelData on control: %v", err)
	}
	if held, open := pair.session.ChannelBufferedAmount(rdevControlChannelLabel); !open || held > 1<<20 {
		t.Fatalf("control: held=%d open=%v, want an open channel holding at most what was sent", held, open)
	}
	// Bytes queued faster than the loopback drains them are counted.
	chunk := make([]byte, 64<<10)
	for i := 0; i < 64; i++ {
		if err := pair.session.SendChannelData(rdevControlChannelLabel, chunk); err != nil {
			t.Fatalf("send %d: %v", i, err)
		}
	}
	if held, open := pair.session.ChannelBufferedAmount(rdevControlChannelLabel); !open || held == 0 {
		t.Fatalf("after 4 MiB queued at once: held=%d open=%v, want some held", held, open)
	}
	if _, open := pair.session.ChannelBufferedAmount("llv-control-v1"); open {
		t.Fatal("a label this session never created reads as open")
	}
}

// waitSendChannelData retries until the channel is open at BOTH ends or the deadline passes.
// readiness proves the session's end opened; the answerer's end is a different end of the same
// channel, and a `terminal` send has no readiness term to wait on at all.
func waitSendChannelData(session *Session, label string, payload []byte) error {
	deadline := time.Now().Add(10 * time.Second)
	for {
		err := session.SendChannelData(label, payload)
		if err == nil || time.Now().After(deadline) || !strings.Contains(err.Error(), "not open") {
			return err
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// awaitChannelOpen blocks until the SESSION reported this label open. It replaces WaitReady where a
// test only needed "my end of this channel is up": readiness also requires a bound video track, so
// using it as a channel signal would couple every channel test to a subscription.
func awaitChannelOpen(t *testing.T, pair *offerPair, label string) {
	t.Helper()
	deadline := time.After(15 * time.Second)
	var seen []string
	for {
		select {
		case opened := <-pair.opens:
			if opened == label {
				return
			}
			seen = append(seen, opened)
		case <-deadline:
			t.Fatalf("the session never reported %q open; it reported %v", label, seen)
		}
	}
}

func sortedKeys(set map[string]bool) []string {
	out := make([]string, 0, len(set))
	for key := range set {
		out = append(out, key)
	}
	sort.Strings(out)
	return out
}

// TestRdevChannelLabelOrderIsTheABIChannelNumber pins the one thing that is an ABI and looks like a
// slice literal.
//
// `rdevChannelLabels`' INDEX is the `int channel` that crosses `pion_bridge.h`
// (`pion_on_datachannel_open(ctx, int channel)`, `pion_peer_send_data(h, int channel, …)`) and lands
// in Swift as `PionChannel: Int32 { case terminal = 0, input = 1, control = 2 }`. There is no
// translation table — the ordering IS the contract — and until now nothing tested it, so reordering
// the literal would silently route the terminal's raw PTY bytes onto the control channel's JSON
// parser and vice versa. Every symptom of that is downstream and confusing: a client whose control
// messages stop parsing and whose terminal fills with JSON.
//
// The numbers are written out rather than derived from the slice, deliberately: deriving them from
// the thing under test is how a guard comes to restate its subject.
func TestRdevChannelLabelOrderIsTheABIChannelNumber(t *testing.T) {
	expected := []struct {
		channel int
		label   string
	}{
		{0, rdevTerminalChannelLabel},
		{1, rdevInputChannelLabel},
		{2, rdevControlChannelLabel},
		{3, rdevBulkChannelLabel},
	}
	if len(rdevChannelLabels) != len(expected) {
		t.Fatalf("rdevChannelLabels has %d entries, want %d — a channel added or removed here is an "+
			"ABI change that Swift's PionChannel and pion_bridge.h must make too",
			len(rdevChannelLabels), len(expected))
	}
	for _, want := range expected {
		if got, ok := rdevChannelLabel(want.channel); !ok || got != want.label {
			t.Fatalf("channel %d maps to (%q, %v), want %q. This index is the `int channel` that "+
				"crosses pion_bridge.h and arrives in Swift as PionChannel.%s",
				want.channel, got, ok, want.label, want.label)
		}
		if got, ok := rdevChannelIndex(want.label); !ok || got != want.channel {
			t.Fatalf("label %q maps to (%d, %v), want %d", want.label, got, ok, want.channel)
		}
	}
	// The two directions must be inverse, which is what makes a message sent on a channel arrive on
	// the same one. Checked over the whole set rather than the three above, so an entry appended
	// later is covered without editing this.
	for index, label := range rdevChannelLabels {
		if back, ok := rdevChannelIndex(label); !ok || back != index {
			t.Fatalf("rdevChannelIndex(%q) = (%d, %v), want %d", label, back, ok, index)
		}
	}
	if _, ok := rdevChannelLabel(len(rdevChannelLabels)); ok {
		t.Fatal("a channel number past the end resolved to a label; the ABI has no such channel")
	}
}
