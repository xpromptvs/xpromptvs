package main

import "fmt"

func recoveryWireFingerprint(packet []byte) string {
	hash := uint64(14_695_981_039_346_656_037)
	for _, value := range packet {
		hash ^= uint64(value)
		hash *= 1_099_511_628_211
	}
	return fmt.Sprintf("%016x", hash)
}
