package main

import (
	"encoding/json"
	"errors"
	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"
	"reflect"
	"strings"
	"testing"
	"time"
)

// Read the custom fields independently of the sender, following the pinned
// libwebrtc parser's bit order. Template 1 remains the existing one-chain L1T1.
func readReferenceDescriptor(t *testing.T, b []byte) (diffs []uint16, chain uint8, dti uint8) {
	t.Helper()
	if len(b) < 4 || b[0]&63 != 1 {
		t.Fatalf("not an inter descriptor: %x", b)
	}
	bit := 24
	read := func(n int) uint16 {
		var v uint16
		for i := 0; i < n; i++ {
			if bit >= len(b)*8 {
				t.Fatal("truncated descriptor")
			}
			v = v<<1 | uint16((b[bit/8]>>(7-bit%8))&1)
			bit++
		}
		return v
	}
	if read(5) != 7 {
		t.Fatalf("custom DTI, dependencies and chain required: %x", b)
	}
	dti = uint8(read(2))
	for {
		size := read(2)
		if size == 0 {
			break
		}
		diffs = append(diffs, read(int(size)*4)+1)
	}
	chain = uint8(read(8))
	return
}
func TestReferenceDescriptorPreservesChainAndSwitchAcrossRollover(t *testing.T) {
	for _, distance := range []uint16{1, 30, 255} {
		b, err := marshalReferenceDependencyDescriptor(0x10000, true, true, []uint16{distance}, uint8(distance), true)
		if err != nil {
			t.Fatal(err)
		}
		diffs, chain, dti := readReferenceDescriptor(t, b)
		if !reflect.DeepEqual(diffs, []uint16{distance}) || chain != uint8(distance) || dti != 2 || b[1] != 0 || b[2] != 0 {
			t.Fatalf("incorrect recovery: %x", b)
		}
	}
	b, err := marshalReferenceDependencyDescriptor(100, true, true, []uint16{1, 2, 4, 6}, 1, false)
	if err != nil {
		t.Fatal(err)
	}
	diffs, chain, dti := readReferenceDescriptor(t, b)
	if !reflect.DeepEqual(diffs, []uint16{1, 2, 4, 6}) || chain != 1 || dti != 3 {
		t.Fatalf("missing normal dependencies: %x", b)
	}
	// Previous-frame-only signaling cannot recover a decoder that has only frame 70.
	good, _ := marshalReferenceDependencyDescriptor(100, true, true, []uint16{30}, 30, true)
	bad, _ := marshalReferenceDependencyDescriptor(100, true, true, []uint16{1}, 1, true)
	canDecode := func(b []byte) bool {
		d, _, _ := readReferenceDescriptor(t, b)
		for _, delta := range d {
			if 100-int(delta) != 70 {
				return false
			}
		}
		return true
	}
	if !canDecode(good) || canDecode(bad) {
		t.Fatal("dependency falsification was not detected")
	}
}
func TestReferenceLedgerTranslatesFullIDsAndRejectsMissingEdges(t *testing.T) {
	var ledger referenceFrameLedger
	ledger.Reset("epoch")
	ledger.RecordSent(9007199254740993, referenceSendResult{RTPTimestamp: 0xffffffff, WireFrameNumber: 65535, Complete: true})
	diffs, err := ledger.Dependencies("epoch", []uint64{9007199254740993}, 65565)
	if err != nil || !reflect.DeepEqual(diffs, []uint16{30}) {
		t.Fatalf("%v %v", diffs, err)
	}
	for _, epoch := range []string{"epoch", "stale"} {
		if _, err := ledger.Dependencies(epoch, []uint64{42}, 65565); err == nil {
			t.Fatal("fabricated an unavailable dependency")
		}
	}
	ledger.RecordSent(42, referenceSendResult{WireFrameNumber: 65565, Complete: false})
	if _, err := ledger.Dependencies("epoch", []uint64{42}, 65566); err == nil {
		t.Fatal("partial send accepted")
	}
	for i := uint64(0); i < 1024; i++ {
		ledger.RecordSent(i, referenceSendResult{WireFrameNumber: 70000 + i, Complete: true})
	}
	if len(ledger.frames) > 512 {
		t.Fatalf("unbounded ledger: %d", len(ledger.frames))
	}
	ledger.Reset("new")
	if len(ledger.frames) != 0 {
		t.Fatal("old epoch retained")
	}
}

func TestReferencePacketResultUsesActualTimestampAndRejectsPartialSend(t *testing.T) {
	writer := &referenceFailWriter{}
	track := NewFrameTrack("video", "source")
	track.timestamp = 0xfffffff0
	track.dependencyFrameNumber = 65535
	_, err := track.Bind(&fakeTrackLocalContext{id: "ref", ssrc: 10, writer: writer,
		codecs:     []webrtc.RTPCodecParameters{{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeAV1, ClockRate: 90000}, PayloadType: 45}},
		extensions: []webrtc.RTPHeaderExtensionParameter{{URI: playoutDelayURI, ID: 8}, {URI: dependencyDescriptorURI, ID: 9}}})
	if err != nil {
		t.Fatal(err)
	}
	meta := referenceFrameMetadata{Version: 1, Epoch: "epoch", FrameID: "9007199254740993", RefreshSlotMask: 255}
	send := referenceSendResult{}
	frame := OutboundFrame{StreamID: 1, FrameID: 1, Keyframe: true, Dependency: l1t1Dependency(true), Data: testAV1AccessUnit(4000), PresentationNanos: 1, Reference: &meta, ReferenceResult: &send}
	if err := track.WriteAccessUnit(frame); err != nil {
		t.Fatal(err)
	}
	packets := writer.takePackets()
	if !send.Complete || send.RTPTimestamp != packets[0].Timestamp || send.WireFrameNumber != 65535 {
		t.Fatalf("wrong actual send result: %+v", send)
	}
	meta.FrameID = "9007199254740994"
	meta.Dependencies = []string{"9007199254740993"}
	meta.RefreshSlotMask = 1
	frame.Keyframe = false
	frame.Dependency = l1t1Dependency(false)
	frame.FrameID = 2
	frame.PresentationNanos = 33333334
	send = referenceSendResult{}
	writer.failAt = writer.writes + 2 // The first packet succeeds, the second fails.
	if err := track.WriteAccessUnit(frame); err == nil {
		t.Fatal("partial send succeeded")
	}
	if send.Complete {
		t.Fatal("partial send published a successful receipt")
	}
	if _, err := track.referenceLedger.Dependencies("epoch", []uint64{9007199254740994}, 65537); err == nil {
		t.Fatal("partial frame entered ledger")
	}
	writer.failAt = 0
	meta.FrameID = "9007199254740995"
	meta.Dependencies = []string{"9007199254740994"}
	frame.FrameID = 3
	before := writer.writes
	if err := track.WriteAccessUnit(frame); err == nil {
		t.Fatal("missing dependency accepted")
	}
	if writer.writes != before {
		t.Fatal("invalid dependencies sent media")
	}
}

type referenceFailWriter struct {
	recordingTrackWriter
	writes, failAt int
}

func (w *referenceFailWriter) WriteRTP(h *rtp.Header, p []byte) (int, error) {
	w.writes++
	if w.writes == w.failAt {
		return 0, errors.New("injected send failure")
	}
	return w.recordingTrackWriter.WriteRTP(h, p)
}

func TestReferencePartialSendDoesNotWedgeFrameClockOrAnotherStream(t *testing.T) {
	session := &Session{videoTracks: map[int]*videoTrackSlot{}}
	for slot := 0; slot < 2; slot++ {
		writer := &referenceFailWriter{}
		track := NewFrameTrack("video", "source")
		track.bindings["ref"] = &frameTrackBinding{id: "ref", profile: videoCodecProfiles()[0], writer: writer, playoutDelayExtensionID: 8, dependencyDescriptorExtensionID: 9}
		var previous uint64
		track.onFrameStart = func(_ uint64, id uint64) error {
			if id != previous+1 {
				return errors.New("clock skipped or repeated a frame")
			}
			previous = id
			return nil
		}
		session.videoTracks[slot] = &videoTrackSlot{track: track}
	}
	writer := session.videoTracks[0].track.bindings["ref"].writer.(*referenceFailWriter)
	writer.failAt = 2
	m := referenceFrameMetadata{Version: 1, Epoch: "epoch", FrameID: "1", RefreshSlotMask: 255}
	result, err := session.WriteVideoReference(0, testAV1AccessUnit(4000), 1, true, m)
	if err == nil || result.Complete {
		t.Fatal("partial write succeeded")
	}
	writer.failAt = 0
	m.FrameID = "2"
	if result, err = session.WriteVideoReference(0, testAV1AccessUnit(4000), 2, true, m); err != nil || !result.Complete {
		t.Fatalf("recovery after partial send wedged: %+v %v", result, err)
	}
	m.FrameID = "1"
	if result, err = session.WriteVideoReference(1, testAV1AccessUnit(4000), 1, true, m); err != nil || !result.Complete {
		t.Fatalf("unrelated stream affected: %+v %v", result, err)
	}
}

func TestReferenceReceiptRequiresExactSlotGenerationAndCompleteSend(t *testing.T) {
	var ledger referenceFrameLedger
	ledger.Reset("epoch")
	token := referenceToken{Epoch: "epoch", FrameID: "1", Slot: 6, Generation: "1"}
	m := referenceFrameMetadata{Version: 1, Epoch: "epoch", FrameID: "1", RefreshSlotMask: 64, Token: &token}
	result := referenceSendResult{RTPTimestamp: 42, WireFrameNumber: 10, Complete: true}
	ledger.RecordSent(1, result)
	ledger.RecordToken(m, result)
	if !ledger.MatchReceipt(token, "", 42) {
		t.Fatal("complete sent identity not recognized")
	}
	for _, bad := range []referenceToken{{Epoch: "old", FrameID: "1", Slot: 6, Generation: "1"}, {Epoch: "epoch", FrameID: "1", Slot: 6, Generation: "2"}, {Epoch: "epoch", FrameID: "1", Slot: 7, Generation: "1"}} {
		if ledger.MatchReceipt(bad, "", 42) {
			t.Fatal("stale token accepted")
		}
	}
	if ledger.MatchReceipt(token, "unexpected", 42) || ledger.MatchReceipt(token, "", 43) {
		t.Fatal("mismatched receipt accepted")
	}
	for i := uint64(2); i < 600; i++ {
		ledger.RecordSent(i, referenceSendResult{WireFrameNumber: 10 + i, Complete: true})
	}
	if _, err := ledger.Dependencies("epoch", []uint64{1}, 610); err != nil {
		t.Fatal("retained anchor evicted", err)
	}
	ledger.RecordToken(referenceFrameMetadata{RefreshSlotMask: 64}, referenceSendResult{Complete: false})
	if !ledger.MatchReceipt(token, "", 42) {
		t.Fatal("failed send changed retained slot")
	}
	ledger.RecordToken(referenceFrameMetadata{RefreshSlotMask: 64}, result)
	if ledger.MatchReceipt(token, "", 42) {
		t.Fatal("overwritten slot accepted")
	}
	ledger.Reset("new")
	if ledger.MatchReceipt(token, "", 42) {
		t.Fatal("old binding survived reset")
	}
}
func TestReferenceMetadataBoundaryRejectsAmbiguousIdentity(t *testing.T) {
	valid := `{"v":1,"epoch":"e","frameId":"9007199254740993","dependencies":["9007199254740992"],"refreshSlotMask":1}`
	if _, err := parseReferenceMetadata([]byte(valid), false); err != nil {
		t.Fatal(err)
	}
	for _, raw := range []string{
		strings.Replace(valid, `"9007199254740993"`, `9007199254740993`, 1),
		strings.Replace(valid, `"9007199254740993"`, `"09007199254740993"`, 1),
		strings.Replace(valid, `"9007199254740992"`, `"9007199254740993"`, 1),
		strings.Replace(valid, `"e"`, `""`, 1),
		strings.Replace(valid, `"v":1`, `"v":2`, 1),
		strings.Repeat(" ", 4097) + valid,
	} {
		if _, err := parseReferenceMetadata([]byte(raw), false); err == nil {
			t.Fatalf("invalid identity accepted: %.100s", raw)
		}
	}
}

func TestReferenceSentCallbackIsOrderedAndOutsideTrackLocks(t *testing.T) {
	track := NewFrameTrack("video", "source")
	writer := &referenceFailWriter{}
	track.bindings["ref"] = &frameTrackBinding{id: "ref", profile: videoCodecProfiles()[0], writer: writer, playoutDelayExtensionID: 8, dependencyDescriptorExtensionID: 9}
	entry := &videoTrackSlot{track: track}
	peer := &rdevPeer{session: &Session{videoTracks: map[int]*videoTrackSlot{0: entry}}, events: make(chan func(), 64), done: make(chan struct{}), dispatcherDone: make(chan struct{})}
	go peer.dispatch()
	defer func() { close(peer.done); <-peer.dispatcherDone }()
	received := make(chan string, 2)
	token := referenceToken{Epoch: "epoch", FrameID: "1", Slot: 6, Generation: "1"}
	m := referenceFrameMetadata{Version: 1, Epoch: "epoch", FrameID: "1", RefreshSlotMask: 255, Token: &token}
	callback := func(raw []byte) {
		if !track.mutex.TryLock() {
			received <- "track lock held"
			return
		}
		track.mutex.Unlock()
		if !entry.writeMutex.TryLock() {
			received <- "entry lock held"
			return
		}
		entry.writeMutex.Unlock()
		var value struct {
			Metadata referenceFrameMetadata `json:"metadata"`
			Result   referenceSendResult    `json:"result"`
		}
		if json.Unmarshal(raw, &value) != nil || !value.Result.Complete || value.Metadata.Token == nil {
			received <- "invalid send notice"
			return
		}
		received <- value.Metadata.FrameID
	}
	if err := peer.writeReferenceVideo(0, testAV1AccessUnit(4000), 1, true, m, callback); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-received:
		if got != "1" {
			t.Fatal(got)
		}
	case <-time.After(time.Second):
		t.Fatal("no complete send callback")
	}
	writer.failAt = writer.writes + 2
	m.FrameID = "2"
	token.FrameID = "2"
	if err := peer.writeReferenceVideo(0, testAV1AccessUnit(4000), 2, true, m, callback); err == nil {
		t.Fatal("failed write accepted")
	}
	barrier := make(chan struct{})
	peer.enqueue(func() { close(barrier) })
	<-barrier
	select {
	case got := <-received:
		t.Fatal("failed send callback", got)
	default:
	}
}
