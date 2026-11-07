package main

import (
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/pion/webrtc/v4"
)

// LLV's two DataChannel labels. They belong to the ANSWERING path and to nothing else: that
// path RECEIVES its channels (peer.OnDataChannel in newHostSession), classifies them by these
// labels, and validates every payload as an LLV1 binary frame. Stock `llv capture-host` and the
// native `capture-view` receiver both speak them, and they are the comparison arm of the
// certification this integration exists to produce — so they stay exactly as they were.
const (
	inputChannelLabel   = "llv-input-v1"
	controlChannelLabel = "llv-control-v1"

	inputBufferedAmountLimit        = uint64(64 << 10)
	inputBufferedAmountLowThreshold = uint64(32 << 10)

	wireKindInput                          = byte(1)
	wireKindKeyframe                       = byte(2)
	wireKindVideo                          = byte(3)
	wireKindPointer                        = byte(4)
	wireKindInputAcknowledgment            = byte(5)
	wireKindStop                           = byte(6)
	wireKindMeasurementStart               = byte(7)
	wireKindMeasurementStartAcknowledgment = byte(8)
	wireKindDisplayGeometry                = byte(9)
)

var errDataChannelPolicy = errors.New("DataChannel policy violation")

type ChannelKind uint8

const (
	ChannelInput ChannelKind = iota + 1
	ChannelControl
)

type SendDisposition uint8

const (
	SendDispositionSent SendDisposition = iota
	SendDispositionDropped
)

// rdev's three channels — terminal, input, control, the C ABI's slots 0/1/2 — CREATED by the offer path
// (createRdevDataChannels in session.go): on the product the three STREAMS of one `lane` data channel (rdev_lane.go),
// on the TEST-ONLY SCTP baseline (RDEV_TEST_SCTP_CHANNELS) three SCTP channels; `bulk` (slot 3) beside them either way.
//
// THE INVERSION IS THE POINT. LLV's host receives two channels and validates every payload as an
// LLV1 binary frame; rdev's host creates its own and carries whatever the client sends — JSON on
// `control`, JSON on `input`, raw PTY bytes on `terminal`. So the offer path uses NONE of LLV's
// channel protocol: not these labels' classifier, not validateChannelMessage, not the input wire
// kinds above. Input is 100% rdev's, and validateChannelMessage rejects an rdev payload outright
// — measured, by routing one through it on purpose: a control message, which rdev's client sends
// as JSON TEXT, dies at the first check as `DataChannel policy violation: text message`, before
// the LLV1 magic is even looked at.
//
// The baseline's three and `bulk` are ordered and reliable; the lane is unordered and reliable, and each of its
// streams delivers in order (rdev_lane_engine.go). WHAT MATCHED rdev's own bridge exactly — the same three
// LABELS, in the same creation ORDER, with the same `&DataChannelInit{Ordered: &ordered}` and the
// same OnOpen/OnMessage-only wiring — was `startOffer` in the retired host/pion-bridge/peer.go, whose
// `chLabels` map keyed the C ABI's slots 0/1/2 to terminal/input/control in that order. Those slots, labels and
// their order are still the contract: the lane keeps them as its stream numbers and the labels its streams publish
// under, so Swift sees no difference, and the baseline keeps the channels themselves — which is all RdevViewer
// answers (docs/open-threads.md, "RdevViewer on the lane").
//
// ONE THING DELIBERATELY DIFFERS, and it is not "byte for byte" — an earlier draft of this comment
// claimed that, and a reader checking would have found this and wondered which was intended.
// rdev's bridge `continue`s past a failed CreateDataChannel, so a host that could not create
// `control` comes up missing it with no error reported anywhere; createRdevDataChannels tears down
// and fails construction instead. That is the same anti-silent-failure argument as the rest of
// this task, so the DIVERGENCE is intended and the equivalence claim was the thing that was wrong.
const (
	rdevTerminalChannelLabel = "terminal"
	rdevInputChannelLabel    = "input"
	rdevControlChannelLabel  = "control"
	// bulk carries the transfers where throughput matters and a stall does not — the paste/drop protocol and the
	// image viewer's files (docs/superpowers/specs/2026-10-12-terminal-lane-design.md, "Decisions" 2). Reliable,
	// ordered SCTP, ABI slot 3: APPENDED, so slots 0–2 do not move.
	rdevBulkChannelLabel = "bulk"
	// lane is the unordered, reliable channel the three streams ride (rdev_lane.go; why reliable: createRdevDataChannels).
	// NOT an ABI slot: Swift sees terminal, input and control, never the lane.
	laneChannelLabel = "lane"
)

// rdevChannelLabels is the set the offer path creates, in creation order. rdev's own bridge keys
// its ABI slots 0/1/2 to terminal/input/control (chLabels in host/pion-bridge/peer.go), so this
// order is the one Task 7 will map onto.
var rdevChannelLabels = []string{
	rdevTerminalChannelLabel,
	rdevInputChannelLabel,
	rdevControlChannelLabel,
	rdevBulkChannelLabel,
}

// rdevReadinessTerm reports which of maybeReady's two channel terms a given rdev channel's open
// state sets, and whether it sets one at all.
//
// TERMINAL SETS NONE, AND THAT IS THE WHOLE OF "TERMINAL DOES NOT GATE READINESS". It is stated
// once, here, rather than spread between the OnOpen handler and maybeReady, so that the decision
// is a single testable fact instead of a shape one has to reconstruct from two files.
//
// WHY IT IS UNGATED. `terminal` carries only the PTY. Gating engine readiness on it would make
// a shell that failed to spawn, or a terminal channel that failed to open, present as the ENGINE
// failing to start — and maybeReady's unmet-condition branch returns silently, so what the
// operator would actually see is a session that never becomes ready with nothing saying why.
// Video and input do not depend on the terminal, so they must not wait for it.
func rdevReadinessTerm(label string) (ChannelKind, bool) {
	switch label {
	case rdevInputChannelLabel:
		return ChannelInput, true
	case rdevControlChannelLabel:
		return ChannelControl, true
	default:
		return 0, false
	}
}

// classifyChannelLabel is the ANSWERING path's classifier, for channels the remote created. The
// offer path does not use it — it creates its own channels and never consults a label at all.
func classifyChannelLabel(label string) (ChannelKind, error) {
	switch label {
	case inputChannelLabel:
		return ChannelInput, nil
	case controlChannelLabel:
		return ChannelControl, nil
	default:
		return 0, fmt.Errorf("%w: unknown label %q", errDataChannelPolicy, label)
	}
}

func validateChannelMessage(channel ChannelKind, isString bool, data []byte) error {
	if isString {
		return fmt.Errorf("%w: text message", errDataChannelPolicy)
	}
	if len(data) < 8 {
		return fmt.Errorf("%w: truncated wire header", errDataChannelPolicy)
	}
	if string(data[:4]) != "LLV1" {
		return fmt.Errorf("%w: bad wire magic", errDataChannelPolicy)
	}
	if data[4] != 2 {
		return fmt.Errorf("%w: unsupported wire version %d", errDataChannelPolicy, data[4])
	}
	if data[6] != 0 || data[7] != 0 {
		return fmt.Errorf("%w: nonzero reserved bytes", errDataChannelPolicy)
	}
	kind := data[5]
	expectedLength := 0
	switch kind {
	case wireKindInput:
		expectedLength = 24
	case wireKindKeyframe, wireKindInputAcknowledgment, wireKindStop,
		wireKindMeasurementStart, wireKindMeasurementStartAcknowledgment,
		wireKindDisplayGeometry:
		expectedLength = 16
	case wireKindPointer:
		expectedLength = 29
	case wireKindVideo:
		return fmt.Errorf("%w: video kind on DataChannel", errDataChannelPolicy)
	default:
		return fmt.Errorf("%w: unknown wire kind %d", errDataChannelPolicy, kind)
	}
	if len(data) != expectedLength {
		return fmt.Errorf(
			"%w: wire kind %d byte count %d, want %d",
			errDataChannelPolicy,
			kind,
			len(data),
			expectedLength,
		)
	}
	if kind == wireKindPointer {
		x := binary.BigEndian.Uint16(data[24:26])
		y := binary.BigEndian.Uint16(data[26:28])
		if x > 1_919 || y > 1_079 {
			return fmt.Errorf("%w: pointer coordinate %d,%d", errDataChannelPolicy, x, y)
		}
		if data[28]&^byte(0x07) != 0 {
			return fmt.Errorf("%w: pointer buttons 0x%02x", errDataChannelPolicy, data[28])
		}
	}
	if kind == wireKindDisplayGeometry {
		width := binary.BigEndian.Uint32(data[8:12])
		height := binary.BigEndian.Uint32(data[12:16])
		if width == 0 || height == 0 {
			return fmt.Errorf("%w: display geometry %dx%d", errDataChannelPolicy, width, height)
		}
	}
	switch channel {
	case ChannelInput:
		if kind != wireKindInput && kind != wireKindPointer &&
			kind != wireKindInputAcknowledgment &&
			kind != wireKindMeasurementStartAcknowledgment {
			return fmt.Errorf("%w: kind %d on input channel", errDataChannelPolicy, kind)
		}
	case ChannelControl:
		if kind != wireKindKeyframe && kind != wireKindStop &&
			kind != wireKindMeasurementStart && kind != wireKindDisplayGeometry {
			return fmt.Errorf("%w: kind %d on control channel", errDataChannelPolicy, kind)
		}
	default:
		return fmt.Errorf("%w: unknown channel %d", errDataChannelPolicy, channel)
	}
	return nil
}

func inputSendDisposition(state webrtc.DataChannelState, bufferedAmount uint64) SendDisposition {
	if state != webrtc.DataChannelStateOpen || bufferedAmount >= inputBufferedAmountLimit {
		return SendDispositionDropped
	}
	return SendDispositionSent
}
