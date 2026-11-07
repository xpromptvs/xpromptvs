package main

import (
	"encoding/hex"
	"errors"
	"testing"
)

func TestDependencyDescriptorMatchesPinnedLibWebRTCVectors(t *testing.T) {
	for _, test := range []struct {
		name              string
		dependency        AV1Dependency
		first, last       bool
		attachedStructure bool
		wantHex           string
	}{
		{
			name: "L1T1 key structure", dependency: l1t1Dependency(true),
			first: true, last: true, attachedStructure: true,
			wantHex: "c0123480003a410100",
		},
		{
			name:       "L1T2 key structure",
			dependency: AV1Dependency{Mode: AV1ScalabilityL1T2},
			first:      true, last: true, attachedStructure: true,
			wantHex: "c0123480011ea851410108",
		},
		{
			name:       "L1T3 key structure",
			dependency: AV1Dependency{Mode: AV1ScalabilityL1T3},
			first:      true, last: true, attachedStructure: true,
			wantHex: "c01234800214eaa860414d1410208426",
		},
		{name: "template 1 complete", dependency: l1t1Dependency(false), first: true, last: true, wantHex: "c11234"},
		{name: "template 2 complete", dependency: AV1Dependency{Mode: AV1ScalabilityL1T2, TemporalID: 1, TemplateID: 2}, first: true, last: true, wantHex: "c21234"},
		{name: "template 3 complete", dependency: AV1Dependency{Mode: AV1ScalabilityL1T3, TemporalID: 2, TemplateID: 3}, first: true, last: true, wantHex: "c31234"},
		{name: "template 4 complete", dependency: AV1Dependency{Mode: AV1ScalabilityL1T3, TemporalID: 2, TemplateID: 4}, first: true, last: true, wantHex: "c41234"},
		{name: "first only", dependency: l1t1Dependency(false), first: true, wantHex: "811234"},
		{name: "last only", dependency: l1t1Dependency(false), last: true, wantHex: "411234"},
		{name: "middle", dependency: l1t1Dependency(false), wantHex: "011234"},
	} {
		t.Run(test.name, func(t *testing.T) {
			got, err := marshalDependencyDescriptor(
				test.dependency, 0x1234, test.first, test.last, test.attachedStructure,
			)
			if err != nil {
				t.Fatal(err)
			}
			want, err := hex.DecodeString(test.wantHex)
			if err != nil {
				t.Fatal(err)
			}
			if string(got) != string(want) {
				t.Fatalf("descriptor = %x, want %x", got, want)
			}
		})
	}
}

func TestOutboundDependencyDescriptorParsesEmittedTemplates(t *testing.T) {
	for templateID, temporalID := range []uint8{0, 0, 1, 2, 2} {
		for _, boundary := range []struct {
			first bool
			last  bool
		}{
			{}, {first: true}, {last: true}, {first: true, last: true},
		} {
			firstMask := byte(0)
			if boundary.first {
				firstMask = 0x80
			}
			lastMask := byte(0)
			if boundary.last {
				lastMask = 0x40
			}
			parsed, err := parseOutboundDependencyDescriptor([]byte{
				byte(templateID) | firstMask | lastMask, 0x12, 0x34,
			})
			if err != nil {
				t.Fatalf("template %d: %v", templateID, err)
			}
			if parsed.TemplateID != uint8(templateID) || parsed.TemporalID != temporalID ||
				parsed.FirstPacket != boundary.first || parsed.LastPacket != boundary.last {
				t.Fatalf("template %d parsed as %+v", templateID, parsed)
			}
		}
	}
}

func TestOutboundDependencyDescriptorRejectsUnsupportedShape(t *testing.T) {
	for _, data := range [][]byte{{}, {0}, {0, 1}, {5, 0, 0}, {0x25, 0, 0}} {
		if _, err := parseOutboundDependencyDescriptor(data); !errors.Is(err, errDependencyDescriptor) {
			t.Fatalf("descriptor %x error = %v", data, err)
		}
	}
}

func TestDependencyDescriptorValidatesFixedStructuresAndFrameNumber(t *testing.T) {
	wrapped, err := marshalDependencyDescriptor(
		l1t1Dependency(false), 0x1_0000, true, true, false,
	)
	if err != nil || string(wrapped) != string([]byte{0xc1, 0x00, 0x00}) {
		t.Fatalf("wrapped descriptor = %x, %v", wrapped, err)
	}

	for _, test := range []struct {
		name              string
		dependency        AV1Dependency
		first, last       bool
		attachedStructure bool
	}{
		{name: "invalid dependency", dependency: AV1Dependency{}},
		{name: "structure on delta", dependency: l1t1Dependency(false), first: true, attachedStructure: true},
		{name: "structure after first packet", dependency: l1t1Dependency(true), attachedStructure: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			if _, err := marshalDependencyDescriptor(
				test.dependency, 1, test.first, test.last, test.attachedStructure,
			); err == nil {
				t.Fatal("invalid descriptor unexpectedly marshaled")
			}
		})
	}
}
