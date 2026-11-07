package main

import (
	"encoding/binary"
	"errors"
	"fmt"
)

const (
	frameMetadataURI     = "urn:llv:rtp-frame-metadata:1"
	frameMetadataVersion = uint8(1)
	frameMetadataSize    = 52
	frameMetadataKey     = uint8(1 << 0)
)

var errInvalidFrameMetadata = errors.New("invalid frame metadata")

type FrameMetadata struct {
	Version                 uint8
	Keyframe                bool
	StreamID                uint64
	FrameID                 uint64
	PacketIndex             uint16
	PacketCount             uint16
	OriginalAccessUnitBytes uint32
	InputSequence           uint64
	HostProcessingNanos     uint64
	EncodeNanos             uint64
}

func (metadata FrameMetadata) MarshalBinary() ([]byte, error) {
	if err := metadata.validate(); err != nil {
		return nil, err
	}
	result := make([]byte, frameMetadataSize)
	result[0] = metadata.Version
	if metadata.Keyframe {
		result[1] = frameMetadataKey
	}
	binary.BigEndian.PutUint64(result[4:12], metadata.StreamID)
	binary.BigEndian.PutUint64(result[12:20], metadata.FrameID)
	binary.BigEndian.PutUint16(result[20:22], metadata.PacketIndex)
	binary.BigEndian.PutUint16(result[22:24], metadata.PacketCount)
	binary.BigEndian.PutUint32(result[24:28], metadata.OriginalAccessUnitBytes)
	binary.BigEndian.PutUint64(result[28:36], metadata.InputSequence)
	binary.BigEndian.PutUint64(result[36:44], metadata.HostProcessingNanos)
	binary.BigEndian.PutUint64(result[44:52], metadata.EncodeNanos)
	return result, nil
}

func ParseFrameMetadata(data []byte) (FrameMetadata, error) {
	if len(data) != frameMetadataSize {
		return FrameMetadata{}, fmt.Errorf(
			"%w: byte count %d, want %d", errInvalidFrameMetadata, len(data), frameMetadataSize,
		)
	}
	if data[1]&^frameMetadataKey != 0 {
		return FrameMetadata{}, fmt.Errorf("%w: unknown flags 0x%02x", errInvalidFrameMetadata, data[1])
	}
	if data[2] != 0 || data[3] != 0 {
		return FrameMetadata{}, fmt.Errorf("%w: reserved bytes are nonzero", errInvalidFrameMetadata)
	}
	metadata := FrameMetadata{
		Version:                 data[0],
		Keyframe:                data[1]&frameMetadataKey != 0,
		StreamID:                binary.BigEndian.Uint64(data[4:12]),
		FrameID:                 binary.BigEndian.Uint64(data[12:20]),
		PacketIndex:             binary.BigEndian.Uint16(data[20:22]),
		PacketCount:             binary.BigEndian.Uint16(data[22:24]),
		OriginalAccessUnitBytes: binary.BigEndian.Uint32(data[24:28]),
		InputSequence:           binary.BigEndian.Uint64(data[28:36]),
		HostProcessingNanos:     binary.BigEndian.Uint64(data[36:44]),
		EncodeNanos:             binary.BigEndian.Uint64(data[44:52]),
	}
	if err := metadata.validate(); err != nil {
		return FrameMetadata{}, err
	}
	return metadata, nil
}

func (metadata FrameMetadata) validate() error {
	switch {
	case metadata.Version != frameMetadataVersion:
		return fmt.Errorf("%w: version %d", errInvalidFrameMetadata, metadata.Version)
	case metadata.StreamID == 0:
		return fmt.Errorf("%w: zero stream ID", errInvalidFrameMetadata)
	case metadata.PacketCount == 0:
		return fmt.Errorf("%w: zero packet count", errInvalidFrameMetadata)
	case metadata.PacketIndex >= metadata.PacketCount:
		return fmt.Errorf(
			"%w: packet index %d is outside count %d",
			errInvalidFrameMetadata,
			metadata.PacketIndex,
			metadata.PacketCount,
		)
	case metadata.OriginalAccessUnitBytes == 0:
		return fmt.Errorf("%w: zero access-unit byte count", errInvalidFrameMetadata)
	default:
		return nil
	}
}

func (metadata FrameMetadata) sameFrame(other FrameMetadata) bool {
	metadata.PacketIndex = 0
	other.PacketIndex = 0
	return metadata == other
}
