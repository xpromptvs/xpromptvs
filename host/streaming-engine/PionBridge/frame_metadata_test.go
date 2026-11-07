package main

import (
	"bytes"
	"encoding/hex"
	"testing"
)

func TestFrameMetadataFixture(t *testing.T) {
	metadata := FrameMetadata{
		Version:                 1,
		Keyframe:                true,
		StreamID:                0x0102030405060708,
		FrameID:                 0x1112131415161718,
		PacketIndex:             2,
		PacketCount:             3,
		OriginalAccessUnitBytes: 0x20212223,
		InputSequence:           0x3132333435363738,
		HostProcessingNanos:     0x4142434445464748,
		EncodeNanos:             0x5152535455565758,
	}
	want, err := hex.DecodeString(
		"01010000" +
			"0102030405060708" +
			"1112131415161718" +
			"00020003" +
			"20212223" +
			"3132333435363738" +
			"4142434445464748" +
			"5152535455565758",
	)
	if err != nil {
		t.Fatal(err)
	}

	encoded, err := metadata.MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	if len(encoded) != 52 {
		t.Fatalf("metadata length = %d, want 52", len(encoded))
	}
	if !bytes.Equal(encoded, want) {
		t.Fatalf("metadata bytes = %x, want %x", encoded, want)
	}
	decoded, err := ParseFrameMetadata(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if decoded != metadata {
		t.Fatalf("decoded metadata = %#v, want %#v", decoded, metadata)
	}
}

func TestFrameMetadataRejectsInvalidValues(t *testing.T) {
	valid := FrameMetadata{
		Version: 1, StreamID: 1, FrameID: 2, PacketCount: 1,
		OriginalAccessUnitBytes: 1,
	}
	tests := []struct {
		name   string
		mutate func(*FrameMetadata)
	}{
		{"unknown version", func(value *FrameMetadata) { value.Version = 2 }},
		{"zero stream", func(value *FrameMetadata) { value.StreamID = 0 }},
		{"zero packet count", func(value *FrameMetadata) { value.PacketCount = 0 }},
		{"packet index out of range", func(value *FrameMetadata) { value.PacketIndex = 1 }},
		{"zero byte count", func(value *FrameMetadata) { value.OriginalAccessUnitBytes = 0 }},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			value := valid
			test.mutate(&value)
			if _, err := value.MarshalBinary(); err == nil {
				t.Fatal("invalid metadata unexpectedly marshaled")
			}
		})
	}
}

func TestFrameMetadataRejectsMalformedBytes(t *testing.T) {
	valid := FrameMetadata{
		Version: 1, Keyframe: true, StreamID: 1, FrameID: 2,
		PacketCount: 1, OriginalAccessUnitBytes: 1,
	}
	encoded, err := valid.MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name  string
		bytes []byte
	}{
		{"truncated", append([]byte(nil), encoded[:51]...)},
		{"trailing", append(append([]byte(nil), encoded...), 0)},
		{"unknown version", mutateMetadataByte(encoded, 0, 2)},
		{"unknown flags", mutateMetadataByte(encoded, 1, 0x03)},
		{"reserved byte", mutateMetadataByte(encoded, 2, 1)},
		{"zero stream", mutateMetadataRange(encoded, 4, 12, 0)},
		{"zero packet count", mutateMetadataRange(encoded, 22, 24, 0)},
		{"out of range index", mutateMetadataRange(encoded, 20, 22, 1)},
		{"zero byte count", mutateMetadataRange(encoded, 24, 28, 0)},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if _, err := ParseFrameMetadata(test.bytes); err == nil {
				t.Fatal("malformed metadata unexpectedly parsed")
			}
		})
	}
}

func mutateMetadataByte(input []byte, offset int, value byte) []byte {
	result := append([]byte(nil), input...)
	result[offset] = value
	return result
}

func mutateMetadataRange(input []byte, start, end int, final byte) []byte {
	result := append([]byte(nil), input...)
	for index := start; index < end; index++ {
		result[index] = 0
	}
	result[end-1] = final
	return result
}
