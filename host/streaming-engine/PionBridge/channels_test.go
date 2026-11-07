package main

import (
	"encoding/binary"
	"net"
	"testing"
	"time"

	"github.com/pion/webrtc/v4"
)

func TestDataChannelsUseExactReliabilityPolicy(t *testing.T) {
	port := reserveUDPPort(t)
	api, resources, err := newTestViewerAPI(PeerConfig{
		ICEPolicy: ICEPolicyStrict,
		LocalIP:   net.ParseIP("127.0.0.1"),
		RemoteIP:  net.ParseIP("127.0.0.1"), ICEPort: port, SignalPort: port + 1,
		Recovery: RecoveryNACKRTX, RTXMaxAge: 30 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer resources.Close()
	peer, err := api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	defer peer.Close()
	channels, err := createTestViewerDataChannels(peer)
	if err != nil {
		t.Fatal(err)
	}
	if channels.input.Label() != inputChannelLabel || channels.input.Ordered() {
		t.Fatalf("input channel policy = label %q ordered %v", channels.input.Label(), channels.input.Ordered())
	}
	if retransmits := channels.input.MaxRetransmits(); retransmits == nil || *retransmits != 0 {
		t.Fatalf("input max retransmits = %v", retransmits)
	}
	if channels.input.BufferedAmountLowThreshold() != inputBufferedAmountLowThreshold {
		t.Fatalf("input low threshold = %d", channels.input.BufferedAmountLowThreshold())
	}
	if channels.control.Label() != controlChannelLabel || !channels.control.Ordered() {
		t.Fatalf("control channel policy = label %q ordered %v", channels.control.Label(), channels.control.Ordered())
	}
	if channels.control.MaxRetransmits() != nil {
		t.Fatalf("control max retransmits = %v", channels.control.MaxRetransmits())
	}
}

func TestDataChannelsValidateBinaryWireKindsByChannel(t *testing.T) {
	pointer := testWireMessage(wireKindPointer, 29)
	binary.BigEndian.PutUint16(pointer[24:26], 1_919)
	binary.BigEndian.PutUint16(pointer[26:28], 1_079)
	pointer[28] = 0x07
	geometry := testWireMessage(wireKindDisplayGeometry, 16)
	binary.BigEndian.PutUint32(geometry[8:12], 1_024)
	binary.BigEndian.PutUint32(geometry[12:16], 768)
	valid := []struct {
		channel ChannelKind
		data    []byte
	}{
		{ChannelInput, testWireMessage(wireKindInput, 24)},
		{ChannelInput, pointer},
		{ChannelInput, testWireMessage(wireKindInputAcknowledgment, 16)},
		{ChannelInput, testWireMessage(wireKindMeasurementStartAcknowledgment, 16)},
		{ChannelControl, testWireMessage(wireKindKeyframe, 16)},
		{ChannelControl, testWireMessage(wireKindStop, 16)},
		{ChannelControl, testWireMessage(wireKindMeasurementStart, 16)},
		{ChannelControl, geometry},
	}
	for _, fixture := range valid {
		if err := validateChannelMessage(fixture.channel, false, fixture.data); err != nil {
			t.Fatalf("valid kind %d on channel %d failed: %v", fixture.data[5], fixture.channel, err)
		}
	}

	invalid := []struct {
		name    string
		channel ChannelKind
		text    bool
		data    []byte
	}{
		{"text", ChannelInput, true, pointer},
		{"short", ChannelInput, false, pointer[:7]},
		{"bad magic", ChannelInput, false, append([]byte{0}, pointer[1:]...)},
		{"bad version", ChannelInput, false, mutateWireByte(pointer, 4, 1)},
		{"reserved", ChannelInput, false, mutateWireByte(pointer, 6, 1)},
		{"control on input", ChannelInput, false, testWireMessage(wireKindStop, 16)},
		{"input on control", ChannelControl, false, pointer},
		{"measurement start on input", ChannelInput, false, testWireMessage(wireKindMeasurementStart, 16)},
		{"measurement ack on control", ChannelControl, false, testWireMessage(wireKindMeasurementStartAcknowledgment, 16)},
		{"geometry on input", ChannelInput, false, geometry},
		{"geometry zero width", ChannelControl, false, mutateWireRange(geometry, 8, []byte{0, 0, 0, 0})},
		{"geometry zero height", ChannelControl, false, mutateWireRange(geometry, 12, []byte{0, 0, 0, 0})},
		{"geometry trailing", ChannelControl, false, append(append([]byte(nil), geometry...), 0)},
		{"video", ChannelInput, false, testWireMessage(wireKindVideo, 8)},
		{"unknown", ChannelInput, false, testWireMessage(99, 8)},
		{"trailing", ChannelControl, false, append(testWireMessage(wireKindStop, 16), 0)},
		{"pointer x", ChannelInput, false, mutateWireRange(pointer, 24, []byte{0x07, 0x80})},
		{"pointer buttons", ChannelInput, false, mutateWireByte(pointer, 28, 0x80)},
	}
	for _, fixture := range invalid {
		t.Run(fixture.name, func(t *testing.T) {
			if err := validateChannelMessage(fixture.channel, fixture.text, fixture.data); err == nil {
				t.Fatal("invalid channel message unexpectedly passed")
			}
		})
	}
	if _, err := classifyChannelLabel("unknown"); err == nil {
		t.Fatal("unknown DataChannel label unexpectedly classified")
	}
}

func TestDataChannelsDropInputWhenNotWritableOrBackpressured(t *testing.T) {
	if inputSendDisposition(webrtc.DataChannelStateOpen, inputBufferedAmountLimit-1) != SendDispositionSent {
		t.Fatal("writable input was dropped")
	}
	if inputSendDisposition(webrtc.DataChannelStateConnecting, 0) != SendDispositionDropped {
		t.Fatal("connecting input was not dropped")
	}
	if inputSendDisposition(webrtc.DataChannelStateOpen, inputBufferedAmountLimit) != SendDispositionDropped {
		t.Fatal("backpressured input was not dropped")
	}
}

func testWireMessage(kind byte, count int) []byte {
	result := make([]byte, count)
	copy(result, []byte{'L', 'L', 'V', '1', 2, kind, 0, 0})
	return result
}

func mutateWireByte(input []byte, offset int, value byte) []byte {
	result := append([]byte(nil), input...)
	result[offset] = value
	return result
}

func mutateWireRange(input []byte, offset int, value []byte) []byte {
	result := append([]byte(nil), input...)
	copy(result[offset:], value)
	return result
}
