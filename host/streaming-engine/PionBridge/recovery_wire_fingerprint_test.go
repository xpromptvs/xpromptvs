package main

import (
	"fmt"
	"hash/fnv"
	"regexp"
	"testing"
)

func referenceRecoveryWireFingerprint(packet []byte) string {
	hash := fnv.New64a()
	_, _ = hash.Write(packet)
	return fmt.Sprintf("%016x", hash.Sum64())
}

func TestRecoveryWireFingerprintMatchesFNV1a(t *testing.T) {
	tests := []struct {
		name   string
		packet []byte
	}{
		{name: "empty", packet: nil},
		{name: "binary", packet: []byte{0x00, 0x01, 0x02, 0xff}},
		{
			name: "visible SRTCP header",
			packet: []byte{
				0x81, 205, 0x00, 0x03, 0x10, 0x20, 0x30, 0x40,
				0xd1, 0xa8, 0x7b, 0x02, 0x55, 0xee, 0x19, 0x80,
			},
		},
	}
	valid := regexp.MustCompile(`^[0-9a-f]{16}$`)
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got := recoveryWireFingerprint(test.packet)
			if got != referenceRecoveryWireFingerprint(test.packet) {
				t.Fatalf("fingerprint = %q, want %q", got, referenceRecoveryWireFingerprint(test.packet))
			}
			if !valid.MatchString(got) {
				t.Fatalf("fingerprint = %q, want 16 lowercase hexadecimal characters", got)
			}
		})
	}
}

func TestRecoveryWireFingerprintChangesWithOneByte(t *testing.T) {
	packet := []byte{0x81, 205, 0, 3, 1, 2, 3, 4, 5, 6, 7, 8}
	mutated := append([]byte(nil), packet...)
	mutated[len(mutated)-1] ^= 1
	if recoveryWireFingerprint(packet) == recoveryWireFingerprint(mutated) {
		t.Fatal("one-byte mutation retained the same wire fingerprint")
	}
}
