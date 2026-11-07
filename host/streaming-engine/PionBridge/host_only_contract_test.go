package main

import (
	"net"
	"reflect"
	"testing"
	"time"
)

func TestProductionPeerAndSessionSurfacesAreHostOnly(t *testing.T) {
	if _, exists := reflect.TypeOf(PeerConfig{}).FieldByName("Role"); exists {
		t.Fatal("production PeerConfig still exposes receiver role selection")
	}
	if _, exists := reflect.TypeOf(Session{}).FieldByName("role"); exists {
		t.Fatal("production Session still stores a receiver role")
	}
	if _, exists := reflect.TypeOf(SessionCallbacks{}).FieldByName("OnVideo"); exists {
		t.Fatal("production callbacks still expose received video")
	}
	configuration := PeerConfig{
		ICEPolicy: ICEPolicyStrict,
		LocalIP:   net.ParseIP("127.0.0.1"), RemoteIP: net.ParseIP("127.0.0.1"),
		SignalPort: 5_701, ICEPort: 5_700,
		Recovery: RecoveryNACKRTX, RTXMaxAge: 30 * time.Millisecond,
	}
	if err := configuration.Validate(); err != nil {
		t.Fatalf("host-only peer configuration failed: %v", err)
	}
}
