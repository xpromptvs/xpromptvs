package main

import (
	"bytes"
	"testing"

	"github.com/pion/rtp/codecs"
)

func TestAV1NormalizationRemovesOnlyDelimiterAndCanonicalizesSizes(t *testing.T) {
	accessUnit := testAV1AccessUnit(180)
	want := accessUnit[2:]

	for _, mtu := range []uint16{24, 64, 1_000} {
		payloads := (&codecs.AV1Payloader{}).Payload(mtu, accessUnit)
		if len(payloads) == 0 {
			t.Fatalf("MTU %d produced no payloads", mtu)
		}
		got := normalizedAV1(t, payloads)
		if !bytes.Equal(got, want) {
			t.Fatalf("MTU %d normalized bytes = %x, want %x", mtu, got, want)
		}
	}
}

func testAV1AccessUnit(tileBytes int) []byte {
	result := make([]byte, 0, tileBytes+32)
	result = appendTestOBU(result, 2, nil)
	result = appendTestOBU(result, 1, []byte{0x11, 0x22, 0x33})
	result = appendTestOBU(result, 3, []byte{0x44, 0x55})
	tile := make([]byte, tileBytes)
	for index := range tile {
		tile[index] = byte(index)
	}
	return appendTestOBU(result, 4, tile)
}

func appendTestOBU(target []byte, obuType byte, payload []byte) []byte {
	target = append(target, obuType<<3|0x02)
	remaining := uint(len(payload))
	for {
		value := byte(remaining & 0x7f)
		remaining >>= 7
		if remaining != 0 {
			value |= 0x80
		}
		target = append(target, value)
		if remaining == 0 {
			break
		}
	}
	return append(target, payload...)
}
