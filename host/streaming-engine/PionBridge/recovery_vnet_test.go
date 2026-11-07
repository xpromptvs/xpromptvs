package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/rand"
	"net"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"sync"
	"testing"
	"time"

	"github.com/pion/rtp"
	"github.com/pion/transport/v4/vnet"
	"github.com/pion/webrtc/v4"
)

const (
	vnetHostIP           = "10.0.0.1"
	vnetViewerIP         = "10.0.0.2"
	pionTransportVersion = "v4.0.2"
)

type RecoveryVNetEvidence struct {
	Seed                    int64            `json:"seed"`
	PionWebRTCVersion       string           `json:"pionWebRTCVersion"`
	PionTransportVersion    string           `json:"pionTransportVersion"`
	DroppedOriginalOrdinals []uint32         `json:"droppedOriginalOrdinals"`
	Healthy                 RecoverySnapshot `json:"healthy"`
	Repaired                RecoverySnapshot `json:"repaired"`
	Stale                   RecoverySnapshot `json:"stale"`
	Disabled                RecoverySnapshot `json:"disabled"`
	Burst                   RecoverySnapshot `json:"burst"`
}

type recoveryVNetFrame struct {
	Frame       AssembledFrame
	AssembledAt time.Time
}

type recoveryVNetPair struct {
	testing      *testing.T
	router       *vnet.Router
	hostNet      *vnet.Net
	viewNet      *vnet.Net
	hostQueue    *vnet.Queue
	viewQueue    *vnet.Queue
	hostTBF      *vnet.TBFQueue
	viewTBF      *vnet.TBFQueue
	host         *webrtc.PeerConnection
	viewer       *webrtc.PeerConnection
	track        *FrameTrack
	hostAPI      *peerAPIResources
	viewAPI      *peerAPIResources
	frames       chan recoveryVNetFrame
	errors       chan error
	requests     chan uint64
	onRecovery   func()
	controller   *recoveryImpairmentController
	closeOnce    sync.Once
	closeErr     error
	closeTimeout time.Duration

	receiverMutex   sync.Mutex
	receiverDone    chan struct{}
	receiverStarted bool
	receiverClosing bool
}

func TestRecoveryVNetHealthy(t *testing.T) {
	pair := newRecoveryVNetPair(t, RecoveryNACKRTX, 30*time.Millisecond, 0)
	for frameID := uint64(1); frameID <= 30; frameID++ {
		pair.sendFrame(frameID, frameID == 1)
		frame := pair.waitFrame()
		if frame.Metadata.FrameID != frameID {
			t.Fatalf("received frame %d, want %d", frame.Metadata.FrameID, frameID)
		}
	}
	if snapshot := pair.combinedRecovery(); snapshot != (RecoverySnapshot{}) {
		t.Fatalf("healthy recovery counters = %#v", snapshot)
	}
}

func TestRecoveryVNetCloseWaitsForResponderCacheDrain(t *testing.T) {
	cache := &ResponderCacheCounters{}
	cache.adjust(1, 1_200)
	pair := &recoveryVNetPair{
		hostAPI:      &peerAPIResources{responderCache: cache},
		receiverDone: make(chan struct{}),
	}
	drained := make(chan struct{})
	go func() {
		time.Sleep(10 * time.Millisecond)
		cache.adjust(-1, -1_200)
		close(drained)
	}()
	if err := pair.Close(); err != nil {
		t.Fatal(err)
	}
	snapshot := cache.Snapshot()
	<-drained
	if snapshot.PacketsCurrent != 0 || snapshot.BytesCurrent != 0 {
		t.Fatalf("close returned before responder cache drained: %#v", snapshot)
	}
}

func TestRecoveryVNetRepairsSingleOriginalLoss(t *testing.T) {
	pair := newRecoveryVNetPair(t, RecoveryNACKRTX, 30*time.Millisecond, 0)
	dropped := pair.dropOriginalOrdinals(map[uint32]struct{}{2: {}})
	pair.sendFrame(1, true)
	snapshot := pair.waitRecovery(func(value RecoverySnapshot) bool {
		return value.NACKSequencesSent > 0 && value.NACKSequencesReceived > 0 &&
			value.RTXPacketsSent > 0 && value.RTXPacketsReceived > 0 && value.PacketsRepaired > 0
	})
	pair.sendFrame(2, false)
	for wanted := uint64(1); wanted <= 2; wanted++ {
		if frame := pair.waitFrame(); frame.Metadata.FrameID != wanted {
			t.Fatalf("repaired frame ID = %d, want %d", frame.Metadata.FrameID, wanted)
		}
	}
	if len(dropped()) != 1 || snapshot.RecoveryKeyframeRequests != 0 {
		t.Fatalf("single-loss evidence dropped=%v stats=%#v", dropped(), snapshot)
	}
}

func TestRecoveryVNetDisabledDoesNotRepair(t *testing.T) {
	pair := newRecoveryVNetPair(t, RecoveryOff, 30*time.Millisecond, 0)
	dropped := pair.dropOriginalOrdinals(map[uint32]struct{}{2: {}})
	pair.sendFrame(1, true)
	pair.sendFrame(2, false)
	if frame := pair.waitFrame(); frame.Metadata.FrameID != 2 {
		t.Fatalf("recovery-off first completed frame = %d, want 2", frame.Metadata.FrameID)
	}
	pair.sendFrame(3, true)
	if frame := pair.waitFrame(); frame.Metadata.FrameID != 3 {
		t.Fatalf("recovery-off keyframe = %d, want 3", frame.Metadata.FrameID)
	}
	if len(dropped()) != 1 || pair.combinedRecovery() != (RecoverySnapshot{}) {
		t.Fatalf("disabled evidence dropped=%v stats=%#v", dropped(), pair.combinedRecovery())
	}
}

func TestRecoveryVNetStaleNACKRequestsOneKeyframe(t *testing.T) {
	pair := newRecoveryVNetPair(t, RecoveryNACKRTX, 5*time.Millisecond, 10*time.Millisecond)
	pair.dropOriginalOrdinals(map[uint32]struct{}{2: {}})
	pair.sendFrame(1, true)
	select {
	case streamID := <-pair.requests:
		if streamID != 0 {
			t.Fatalf("stale sender stream ID = %d, want 0", streamID)
		}
	case err := <-pair.errors:
		t.Fatalf("stale receiver failed: %v", err)
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for stale recovery request")
	}
	snapshot := pair.waitRecovery(func(value RecoverySnapshot) bool {
		return value.NACKSequencesReceived > 0 && value.StaleRTXRequestsSuppressed > 0 &&
			value.RecoveryKeyframeRequests == 1
	})
	if snapshot.RTXPacketsSent != 0 || snapshot.PacketsRepaired != 0 {
		t.Fatalf("stale recovery unexpectedly repaired: %#v", snapshot)
	}
}

func TestRecoveryVNetLostNACKExpiresToKeyframe(t *testing.T) {
	pair := newRecoveryVNetPair(t, RecoveryNACKRTX, 30*time.Millisecond, 0)
	pair.dropOriginalOrdinals(map[uint32]struct{}{2: {}})
	pair.addFilter(func(chunk vnet.Chunk) bool {
		source, sourceOK := chunk.SourceAddr().(*net.UDPAddr)
		destination, destinationOK := chunk.DestinationAddr().(*net.UDPAddr)
		data := chunk.UserData()
		if sourceOK && destinationOK && source.IP.String() == vnetViewerIP &&
			destination.IP.String() == vnetHostIP && len(data) >= 2 &&
			data[1] >= 192 && data[1] <= 223 {
			return false
		}
		return true
	})
	pair.sendFrame(1, true)
	pair.waitRecovery(func(value RecoverySnapshot) bool { return value.NACKSequencesSent > 0 })
	pair.sendFrame(2, false)
	time.Sleep(35 * time.Millisecond)
	pair.sendFrame(3, false)
	select {
	case streamID := <-pair.requests:
		if streamID != 91 {
			t.Fatalf("lost-NACK recovery stream = %d, want 91", streamID)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for lost-NACK expiry")
	}
	snapshot := pair.waitRecovery(func(value RecoverySnapshot) bool {
		return value.IncompleteFramesExpired == 1 && value.RecoveryKeyframeRequests == 1
	})
	if snapshot.NACKSequencesReceived != 0 || snapshot.RTXPacketsSent != 0 ||
		snapshot.PacketsRepaired != 0 {
		t.Fatalf("lost NACK created false recovery: %#v", snapshot)
	}
	pair.sendFrame(4, true)
	if frame := pair.waitUntilFrame(4); frame.Metadata.FrameID != 4 {
		t.Fatalf("lost-NACK resume frame = %d", frame.Metadata.FrameID)
	}
}

func TestRecoveryVNetLostFirstRTXFallsBack(t *testing.T) {
	pair := newRecoveryVNetPair(t, RecoveryNACKRTX, 30*time.Millisecond, 0)
	pair.dropOriginalOrdinals(map[uint32]struct{}{2: {}})
	var mutex sync.Mutex
	droppedRTX := 0
	pair.addFilter(func(chunk vnet.Chunk) bool {
		packet, ok := vnetRTPPacket(chunk, vnetHostIP, vnetViewerIP)
		if !ok || packet.PayloadType != rtxPayloadType {
			return true
		}
		mutex.Lock()
		defer mutex.Unlock()
		droppedRTX++
		return false
	})
	pair.sendFrame(1, true)
	pair.waitRecovery(func(value RecoverySnapshot) bool {
		return value.RTXPacketsSent > 0
	})
	pair.sendFrame(2, false)
	time.Sleep(35 * time.Millisecond)
	pair.sendFrame(3, false)
	snapshot := pair.waitRecovery(func(value RecoverySnapshot) bool {
		return value.IncompleteFramesExpired == 1 && value.RecoveryKeyframeRequests == 1
	})
	mutex.Lock()
	dropped := droppedRTX
	mutex.Unlock()
	if dropped < 1 || snapshot.PacketsRepaired != 0 || snapshot.RTXPacketsReceived != 0 {
		t.Fatalf("lost-first-RTX evidence dropped=%d stats=%#v", dropped, snapshot)
	}
}

func TestRecoveryVNetSeededBurstIsRepeatable(t *testing.T) {
	firstDropped, first := runSeededBurst(t)
	secondDropped, second := runSeededBurst(t)
	// Pion may batch the same missing RTP sequences into a different number of
	// RTCP NACK packets when scheduler timing changes, especially under -race.
	// Sequence-level recovery and all resulting transport outcomes must repeat.
	first.NACKPacketsSent = 0
	first.NACKPacketsReceived = 0
	second.NACKPacketsSent = 0
	second.NACKPacketsReceived = 0
	if !slices.Equal(firstDropped, secondDropped) || first != second {
		t.Fatalf(
			"burst runs differ: dropped %v/%v stats %#v/%#v",
			firstDropped, secondDropped, first, second,
		)
	}
}

func TestRecoveryVNetEvidence(t *testing.T) {
	evidence := RecoveryVNetEvidence{
		Seed: 8_854, PionWebRTCVersion: pionWebRTCVersion,
		PionTransportVersion: pionTransportVersion,
	}
	t.Run("healthy", func(t *testing.T) {
		pair := newRecoveryVNetPair(t, RecoveryNACKRTX, 30*time.Millisecond, 0)
		for frameID := uint64(1); frameID <= 30; frameID++ {
			pair.sendFrame(frameID, frameID == 1)
			pair.waitFrame()
		}
		evidence.Healthy = pair.combinedRecovery()
	})
	t.Run("repaired", func(t *testing.T) {
		pair := newRecoveryVNetPair(t, RecoveryNACKRTX, 30*time.Millisecond, 0)
		pair.dropOriginalOrdinals(map[uint32]struct{}{2: {}})
		pair.sendFrame(1, true)
		evidence.Repaired = pair.waitRecovery(func(value RecoverySnapshot) bool {
			return value.PacketsRepaired == 1
		})
		pair.sendFrame(2, false)
		pair.waitUntilFrame(2)
		evidence.Repaired = pair.combinedRecovery()
	})
	t.Run("stale", func(t *testing.T) {
		pair := newRecoveryVNetPair(t, RecoveryNACKRTX, 5*time.Millisecond, 10*time.Millisecond)
		pair.dropOriginalOrdinals(map[uint32]struct{}{2: {}})
		pair.sendFrame(1, true)
		evidence.Stale = pair.waitRecovery(func(value RecoverySnapshot) bool {
			return value.StaleRTXRequestsSuppressed > 0 && value.RecoveryKeyframeRequests == 1
		})
	})
	t.Run("disabled", func(t *testing.T) {
		pair := newRecoveryVNetPair(t, RecoveryOff, 30*time.Millisecond, 0)
		pair.dropOriginalOrdinals(map[uint32]struct{}{2: {}})
		pair.sendFrame(1, true)
		pair.sendFrame(2, false)
		pair.waitUntilFrame(2)
		evidence.Disabled = pair.combinedRecovery()
	})
	t.Run("burst", func(t *testing.T) {
		evidence.DroppedOriginalOrdinals, evidence.Burst = runSeededBurst(t)
	})

	if evidence.Healthy != (RecoverySnapshot{}) ||
		evidence.Repaired.PacketsRepaired != 1 || evidence.Repaired.RTXPacketsReceived == 0 ||
		evidence.Stale.StaleRTXRequestsSuppressed == 0 ||
		evidence.Stale.RecoveryKeyframeRequests != 1 ||
		evidence.Disabled != (RecoverySnapshot{}) || len(evidence.DroppedOriginalOrdinals) != 5 {
		t.Fatalf("invalid recovery evidence: %#v", evidence)
	}
	if outputPath := os.Getenv("LLV_VNET_EVIDENCE_PATH"); outputPath != "" {
		encoded, err := json.MarshalIndent(evidence, "", "  ")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(filepath.Dir(outputPath), 0o755); err != nil {
			t.Fatal(err)
		}
		encoded = append(encoded, '\n')
		if err := os.WriteFile(outputPath, encoded, 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func runSeededBurst(t *testing.T) ([]uint32, RecoverySnapshot) {
	t.Helper()
	pair := newRecoveryVNetPair(t, RecoveryNACKRTX, time.Second, 0)
	random := rand.New(rand.NewSource(8_854))
	permutation := random.Perm(100)
	selected := make([]uint32, 5)
	wanted := make(map[uint32]struct{}, len(selected))
	for index := range selected {
		selected[index] = uint32(permutation[index] + 1)
		wanted[selected[index]] = struct{}{}
	}
	sort.Slice(selected, func(i, j int) bool { return selected[i] < selected[j] })
	dropped := pair.dropOriginalOrdinals(wanted)
	observedDrops := 0
	for frameID := uint64(1); frameID <= 40; frameID++ {
		pair.sendFrame(frameID, frameID == 1 || frameID == 40)
		time.Sleep(time.Millisecond)
		if count := len(dropped()); count > observedDrops {
			pair.waitRecovery(func(value RecoverySnapshot) bool {
				return value.PacketsRepaired >= uint64(count)
			})
			observedDrops = count
		}
	}
	pair.waitUntilFrame(40)
	time.Sleep(10 * time.Millisecond)
	actual := dropped()
	if !slices.Equal(actual, selected) {
		t.Fatalf("seeded drops = %v, want %v", actual, selected)
	}
	snapshot := pair.combinedRecovery()
	if snapshot.RetainedFramesCurrent != 0 || snapshot.RetainedFramesPeak > defaultRecoveryFrameLimit ||
		(snapshot.PacketsRepaired == 0 && snapshot.RecoveryKeyframeRequests == 0) {
		t.Fatalf("unbounded or inactive burst recovery: %#v", snapshot)
	}
	return actual, snapshot
}

func newRecoveryVNetPair(
	t *testing.T,
	recovery RecoveryMode,
	rtxMaxAge time.Duration,
	minimumDelay time.Duration,
) *recoveryVNetPair {
	t.Helper()
	pair, err := newRecoveryVNetPairWithConfig(t, recoveryVNetPairConfig{
		Recovery:  recovery,
		RTXMaxAge: rtxMaxAge,
		Profile: &recoveryMatrixProfile{
			OneWayDelayMicroseconds: int(minimumDelay / time.Microsecond),
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	return pair
}

func (pair *recoveryVNetPair) writeFrame(frameID uint64, keyframe bool, bytes int) error {
	return pair.track.WriteAccessUnit(OutboundFrame{
		StreamID: 91, FrameID: frameID, InputSequence: frameID,
		Keyframe: keyframe, Dependency: l1t1Dependency(keyframe),
		Data: testAV1AccessUnit(bytes),
	})
}

func (pair *recoveryVNetPair) receiveFrame(ctx context.Context) (AssembledFrame, error) {
	select {
	case received := <-pair.frames:
		return received.Frame, nil
	case err := <-pair.errors:
		return AssembledFrame{}, err
	case <-ctx.Done():
		return AssembledFrame{}, ctx.Err()
	}
}

func (pair *recoveryVNetPair) recoverySnapshot() RecoverySnapshot {
	return pair.combinedRecovery()
}

func (pair *recoveryVNetPair) drain(ctx context.Context) error {
	if pair.controller == nil {
		return nil
	}
	return pair.controller.WaitForDrain(ctx)
}

func (pair *recoveryVNetPair) sendFrame(frameID uint64, keyframe bool) {
	pair.testing.Helper()
	err := pair.writeFrame(frameID, keyframe, 3_000)
	if err != nil {
		pair.testing.Fatal(err)
	}
}

func (pair *recoveryVNetPair) waitFrame() AssembledFrame {
	pair.testing.Helper()
	select {
	case received := <-pair.frames:
		return received.Frame
	case err := <-pair.errors:
		pair.testing.Fatalf("virtual receiver failed: %v", err)
	case <-time.After(3 * time.Second):
		pair.testing.Fatal("timed out waiting for virtual media frame")
	}
	return AssembledFrame{}
}

func (pair *recoveryVNetPair) waitUntilFrame(wanted uint64) AssembledFrame {
	pair.testing.Helper()
	deadline := time.After(3 * time.Second)
	for {
		select {
		case received := <-pair.frames:
			frame := received.Frame
			if frame.Metadata.FrameID == wanted {
				return frame
			}
		case err := <-pair.errors:
			pair.testing.Fatalf("virtual receiver failed: %v", err)
		case <-deadline:
			pair.testing.Fatalf("timed out waiting for virtual frame %d", wanted)
		}
	}
}

func (pair *recoveryVNetPair) addFilter(filter func(vnet.Chunk) bool) {
	pair.router.AddChunkFilter(filter)
}

func (pair *recoveryVNetPair) dropOriginalOrdinals(
	wanted map[uint32]struct{},
) func() []uint32 {
	var mutex sync.Mutex
	ordinal := uint32(0)
	var dropped []uint32
	pair.addFilter(func(chunk vnet.Chunk) bool {
		packet, ok := vnetRTPPacket(chunk, vnetHostIP, vnetViewerIP)
		if !ok || packet.PayloadType != av1PayloadType {
			return true
		}
		mutex.Lock()
		defer mutex.Unlock()
		ordinal++
		if _, shouldDrop := wanted[ordinal]; shouldDrop {
			dropped = append(dropped, ordinal)
			return false
		}
		return true
	})
	return func() []uint32 {
		mutex.Lock()
		defer mutex.Unlock()
		return append([]uint32(nil), dropped...)
	}
}

func vnetRTPPacket(chunk vnet.Chunk, sourceIP, destinationIP string) (*rtp.Packet, bool) {
	source, sourceOK := chunk.SourceAddr().(*net.UDPAddr)
	destination, destinationOK := chunk.DestinationAddr().(*net.UDPAddr)
	if !sourceOK || !destinationOK || source.IP.String() != sourceIP ||
		destination.IP.String() != destinationIP {
		return nil, false
	}
	packet := &rtp.Packet{}
	if err := packet.Unmarshal(chunk.UserData()); err != nil {
		return nil, false
	}
	return packet, true
}

func (pair *recoveryVNetPair) combinedRecovery() RecoverySnapshot {
	host := pair.hostAPI.counters.Snapshot()
	viewer := pair.viewAPI.counters.Snapshot()
	return addRecoverySnapshots(host, viewer)
}

func (pair *recoveryVNetPair) waitRecovery(
	ready func(RecoverySnapshot) bool,
) RecoverySnapshot {
	pair.testing.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		snapshot := pair.combinedRecovery()
		if ready(snapshot) {
			return snapshot
		}
		select {
		case err := <-pair.errors:
			pair.testing.Fatalf("virtual recovery failed: %v", err)
		case <-time.After(time.Millisecond):
		}
	}
	snapshot := pair.combinedRecovery()
	pair.testing.Fatalf("timed out waiting for recovery counters: %#v", snapshot)
	return snapshot
}

func addRecoverySnapshots(left, right RecoverySnapshot) RecoverySnapshot {
	return RecoverySnapshot{
		NACKPacketsSent:            left.NACKPacketsSent + right.NACKPacketsSent,
		NACKSequencesSent:          left.NACKSequencesSent + right.NACKSequencesSent,
		NACKPacketsReceived:        left.NACKPacketsReceived + right.NACKPacketsReceived,
		NACKSequencesReceived:      left.NACKSequencesReceived + right.NACKSequencesReceived,
		RTXPacketsSent:             left.RTXPacketsSent + right.RTXPacketsSent,
		RTXBytesSent:               left.RTXBytesSent + right.RTXBytesSent,
		RTXPacketsReceived:         left.RTXPacketsReceived + right.RTXPacketsReceived,
		RTXBytesReceived:           left.RTXBytesReceived + right.RTXBytesReceived,
		PacketsRepaired:            left.PacketsRepaired + right.PacketsRepaired,
		StaleRTXRequestsSuppressed: left.StaleRTXRequestsSuppressed + right.StaleRTXRequestsSuppressed,
		ResponderCacheMisses:       left.ResponderCacheMisses + right.ResponderCacheMisses,
		ResponderCacheEvictions:    left.ResponderCacheEvictions + right.ResponderCacheEvictions,
		RecoveryKeyframeRequests:   left.RecoveryKeyframeRequests + right.RecoveryKeyframeRequests,
		IncompleteFramesExpired:    left.IncompleteFramesExpired + right.IncompleteFramesExpired,
		DependentFramesAbandoned:   left.DependentFramesAbandoned + right.DependentFramesAbandoned,
		RetainedFramesCurrent:      left.RetainedFramesCurrent + right.RetainedFramesCurrent,
		RetainedFramesPeak:         left.RetainedFramesPeak + right.RetainedFramesPeak,
	}
}

func (pair *recoveryVNetPair) Close() error {
	pair.closeOnce.Do(func() {
		closeTimeout := pair.closeTimeout
		if closeTimeout <= 0 {
			closeTimeout = time.Second
		}
		var closeErrors []error
		record := func(operation string, err error) {
			if err != nil {
				closeErrors = append(closeErrors, fmt.Errorf("%s: %w", operation, err))
			}
		}
		pair.receiverMutex.Lock()
		pair.receiverClosing = true
		receiverStarted := pair.receiverStarted
		receiverDone := pair.receiverDone
		pair.receiverMutex.Unlock()
		if pair.viewer != nil {
			record("close recovery viewer", pair.viewer.Close())
		}
		if pair.host != nil {
			record("close recovery host", pair.host.Close())
		}
		if receiverStarted {
			select {
			case <-receiverDone:
			case <-time.After(closeTimeout):
				closeErrors = append(closeErrors, fmt.Errorf(
					"wait for recovery receiver: timed out after %s", closeTimeout,
				))
			}
		}
		if pair.viewAPI != nil {
			record("close recovery viewer API", pair.viewAPI.Close())
		}
		if pair.hostAPI != nil {
			record("close recovery host API", pair.hostAPI.Close())
		}
		record("drain recovery responder caches", pair.waitForResponderCacheDrain(closeTimeout))
		if pair.controller != nil {
			drainContext, cancel := context.WithTimeout(context.Background(), closeTimeout)
			record("drain recovery controller", pair.controller.WaitForDrain(drainContext))
			cancel()
			record("close recovery controller", pair.controller.Close())
		}
		if pair.viewQueue != nil {
			record("close recovery viewer queue", pair.viewQueue.Close())
		}
		if pair.hostQueue != nil {
			record("close recovery host queue", pair.hostQueue.Close())
		}
		if pair.router != nil {
			record("stop recovery router", pair.router.Stop())
		}
		pair.closeErr = errors.Join(closeErrors...)
	})
	return pair.closeErr
}

func (pair *recoveryVNetPair) waitForResponderCacheDrain(timeout time.Duration) error {
	snapshot := func() ResponderCacheSnapshot {
		var host, viewer ResponderCacheSnapshot
		if pair.hostAPI != nil && pair.hostAPI.responderCache != nil {
			host = pair.hostAPI.ResponderCacheSnapshot()
		}
		if pair.viewAPI != nil && pair.viewAPI.responderCache != nil {
			viewer = pair.viewAPI.ResponderCacheSnapshot()
		}
		return addResponderCacheSnapshots(host, viewer)
	}
	if current := snapshot(); current.PacketsCurrent == 0 && current.BytesCurrent == 0 {
		return nil
	}
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	ticker := time.NewTicker(time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			current := snapshot()
			if current.PacketsCurrent == 0 && current.BytesCurrent == 0 {
				return nil
			}
		case <-deadline.C:
			current := snapshot()
			return fmt.Errorf(
				"timed out after %s with packets=%d bytes=%d",
				timeout, current.PacketsCurrent, current.BytesCurrent,
			)
		}
	}
}
