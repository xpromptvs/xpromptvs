package main

import (
	"encoding/binary"
	"errors"
	"fmt"
)

var errDependencyDescriptor = errors.New("dependency descriptor failed")

type ParsedDependencyDescriptor struct {
	TemplateID  uint8
	TemporalID  uint8
	FirstPacket bool
	LastPacket  bool
}

func parseOutboundDependencyDescriptor(data []byte) (ParsedDependencyDescriptor, error) {
	if len(data) < 3 {
		return ParsedDependencyDescriptor{}, fmt.Errorf(
			"%w: outbound descriptor is %d bytes", errDependencyDescriptor, len(data),
		)
	}
	templateID := data[0] & 0x3f
	var temporalID uint8
	switch templateID {
	case 0, 1:
	case 2:
		temporalID = 1
	case 3, 4:
		temporalID = 2
	default:
		return ParsedDependencyDescriptor{}, fmt.Errorf(
			"%w: unsupported outbound template %d", errDependencyDescriptor, templateID,
		)
	}
	return ParsedDependencyDescriptor{
		TemplateID: templateID, TemporalID: temporalID,
		FirstPacket: data[0]&0x80 != 0,
		LastPacket:  data[0]&0x40 != 0,
	}, nil
}

var dependencyStructures = map[AV1ScalabilityMode][]byte{
	AV1ScalabilityL1T1: {0x80, 0x00, 0x3a, 0x41, 0x01, 0x00},
	AV1ScalabilityL1T2: {0x80, 0x01, 0x1e, 0xa8, 0x51, 0x41, 0x01, 0x08},
	AV1ScalabilityL1T3: {
		0x80, 0x02, 0x14, 0xea, 0xa8, 0x60, 0x41,
		0x4d, 0x14, 0x10, 0x20, 0x84, 0x26,
	},
}

func marshalDependencyDescriptor(
	dependency AV1Dependency,
	frameNumber uint64,
	firstPacket bool,
	lastPacket bool,
	attachStructure bool,
) ([]byte, error) {
	keyframe := dependency.TemplateID == 0
	if err := dependency.Validate(keyframe); err != nil {
		return nil, fmt.Errorf("%w: %v", errDependencyDescriptor, err)
	}
	if attachStructure && (!keyframe || !firstPacket) {
		return nil, fmt.Errorf(
			"%w: structure requires the first keyframe packet",
			errDependencyDescriptor,
		)
	}
	structure := []byte(nil)
	if attachStructure {
		structure = dependencyStructures[dependency.Mode]
		if len(structure) == 0 {
			return nil, fmt.Errorf(
				"%w: unsupported mode %d", errDependencyDescriptor, dependency.Mode,
			)
		}
	}
	encoded := make([]byte, 3, 3+len(structure))
	encoded[0] = dependency.TemplateID
	if firstPacket {
		encoded[0] |= 0x80
	}
	if lastPacket {
		encoded[0] |= 0x40
	}
	binary.BigEndian.PutUint16(encoded[1:3], uint16(frameNumber))
	encoded = append(encoded, structure...)
	return encoded, nil
}

// Extends template 1 of the existing one-chain L1T1 structure. In particular a
// recovery uses the anchor for BOTH its frame dependency and chain difference.
// A switch DTI does not make this an independently decodable keyframe.
func marshalReferenceDependencyDescriptor(frame uint64, first, last bool, diffs []uint16, chain uint8, recovery bool) ([]byte, error) {
	if len(diffs) == 0 || len(diffs) > 7 || chain == 0 || (recovery && (len(diffs) != 1 || diffs[0] > 255 || uint16(chain) != diffs[0])) {
		return nil, errDependencyDescriptor
	}
	b := []byte{1, byte(frame >> 8), byte(frame)}
	if first {
		b[0] |= 128
	}
	if last {
		b[0] |= 64
	}
	bit := 24
	put := func(value uint16, n int) {
		for i := n - 1; i >= 0; i-- {
			if bit/8 == len(b) {
				b = append(b, 0)
			}
			b[bit/8] |= byte((value>>i)&1) << (7 - bit%8)
			bit++
		}
	}
	put(7, 5) // no structure/target mask, custom DTI + frame diffs + chain diff
	if recovery {
		put(2, 2)
	} else {
		put(3, 2)
	}
	for _, d := range diffs {
		if d == 0 || d > 4096 {
			return nil, errDependencyDescriptor
		}
		if d <= 16 {
			put(1, 2)
			put(d-1, 4)
		} else if d <= 256 {
			put(2, 2)
			put(d-1, 8)
		} else {
			put(3, 2)
			put(d-1, 12)
		}
	}
	put(0, 2)
	put(uint16(chain), 8)
	return b, nil
}
