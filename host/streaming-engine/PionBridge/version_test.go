package main

import "testing"

func TestVersionMetadata(t *testing.T) {
	if pionWebRTCVersion != "v4.2.15" {
		t.Fatalf("unexpected Pion version %q", pionWebRTCVersion)
	}
	if got := versionString(); got != "pion-webrtc/v4.2.15" {
		t.Fatalf("unexpected version string %q", got)
	}
}
