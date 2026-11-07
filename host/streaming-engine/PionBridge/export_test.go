package main

import (
	"bytes"
	"encoding/json"
	"sync"
	"testing"
	"time"
)

func TestExportConstants(t *testing.T) {
	if RecoveryNACKRTX != 1 || RecoveryOff != 2 || RecoveryNACKRTXFlexFEC != 3 {
		t.Fatalf(
			"recovery ABI values = %d, %d, %d",
			RecoveryNACKRTX, RecoveryOff, RecoveryNACKRTXFlexFEC,
		)
	}
	if FlexFECTierOff != 0 || FlexFECTierLow != 1 ||
		FlexFECTierMedium != 2 || FlexFECTierHigh != 3 {
		t.Fatalf(
			"FlexFEC tier values = %d, %d, %d, %d",
			FlexFECTierOff, FlexFECTierLow, FlexFECTierMedium, FlexFECTierHigh,
		)
	}
	if RTXAgeFixed != 1 || RTXAgeRTT != 2 {
		t.Fatalf("RTX age ABI values = %d, %d", RTXAgeFixed, RTXAgeRTT)
	}
}

func TestParseABIRTXAgePolicy(t *testing.T) {
	for _, test := range []struct {
		name                   string
		mode                   uint8
		floor, multiplier, cap uint16
		want                   RTXAgePolicyConfig
		wantErr                bool
	}{
		{
			name: "legacy zero fields", floor: 30,
			want: RTXAgePolicyConfig{Mode: RTXAgeFixed, Floor: 30 * time.Millisecond,
				Cap: 30 * time.Millisecond, MultiplierMilli: 1_000},
		},
		{
			name: "explicit fixed", mode: 1, floor: 75,
			want: RTXAgePolicyConfig{Mode: RTXAgeFixed, Floor: 75 * time.Millisecond,
				Cap: 75 * time.Millisecond, MultiplierMilli: 1_000},
		},
		{
			name: "RTT", mode: 2, floor: 30, multiplier: 1_250, cap: 300,
			want: RTXAgePolicyConfig{Mode: RTXAgeRTT, Floor: 30 * time.Millisecond,
				Cap: 300 * time.Millisecond, MultiplierMilli: 1_250},
		},
		{name: "fixed multiplier", mode: 1, floor: 30, multiplier: 1_250, wantErr: true},
		{name: "fixed cap", mode: 1, floor: 30, cap: 300, wantErr: true},
		{name: "RTT missing multiplier", mode: 2, floor: 30, cap: 300, wantErr: true},
		{name: "RTT missing cap", mode: 2, floor: 30, multiplier: 1_250, wantErr: true},
		{name: "RTT cap below floor", mode: 2, floor: 300, multiplier: 1_250, cap: 30, wantErr: true},
		{name: "unknown mode", mode: 3, floor: 30, wantErr: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			got, err := parseABIRTXAgePolicy(test.mode, test.floor, test.multiplier, test.cap)
			if (err != nil) != test.wantErr {
				t.Fatalf("parse error = %v, wantErr %t", err, test.wantErr)
			}
			if err == nil && got != test.want {
				t.Fatalf("policy = %#v, want %#v", got, test.want)
			}
		})
	}
}

func TestParseABIRecoveryConfiguration(t *testing.T) {
	if FlexFECPolicyAdaptive != 1 || FlexFECPolicyOff != 2 || FlexFECPolicyLow != 3 ||
		FlexFECPolicyMedium != 4 || FlexFECPolicyHigh != 5 {
		t.Fatalf(
			"FlexFEC policy ABI values = %d, %d, %d, %d, %d",
			FlexFECPolicyAdaptive, FlexFECPolicyOff, FlexFECPolicyLow,
			FlexFECPolicyMedium, FlexFECPolicyHigh,
		)
	}
	for _, test := range []struct {
		name     string
		mode     uint8
		age      uint16
		wantMode RecoveryMode
		wantAge  time.Duration
		wantErr  bool
	}{
		{name: "nack RTX", mode: 1, age: 30, wantMode: RecoveryNACKRTX, wantAge: 30 * time.Millisecond},
		{name: "off", mode: 2, age: 1_000, wantMode: RecoveryOff, wantAge: time.Second},
		{name: "NACK RTX FlexFEC", mode: 3, age: 30, wantMode: RecoveryNACKRTXFlexFEC, wantAge: 30 * time.Millisecond},
		{name: "zero mode", age: 30, wantErr: true},
		{name: "unknown mode", mode: 4, age: 30, wantErr: true},
		{name: "zero age", mode: 1, wantErr: true},
		{name: "age too large", mode: 1, age: 1_001, wantErr: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			mode, age, err := parseABIRecovery(test.mode, test.age)
			if test.wantErr {
				if err == nil {
					t.Fatalf("invalid recovery passed: mode=%d age=%d", test.mode, test.age)
				}
				return
			}
			if err != nil || mode != test.wantMode || age != test.wantAge {
				t.Fatalf("recovery = %d, %s, %v; want %d, %s", mode, age, err, test.wantMode, test.wantAge)
			}
		})
	}
	for raw := uint8(1); raw <= 5; raw++ {
		policy, err := parseABIFlexFECPolicy(raw)
		if err != nil || uint8(policy) != raw {
			t.Fatalf("FlexFEC policy %d = %d, %v", raw, policy, err)
		}
	}
	for _, raw := range []uint8{0, 6, 255} {
		if _, err := parseABIFlexFECPolicy(raw); err == nil {
			t.Fatalf("invalid FlexFEC policy %d passed", raw)
		}
	}
	for _, test := range []struct {
		value   uint8
		want    bool
		wantErr bool
	}{{value: 0}, {value: 1, want: true}, {value: 2, wantErr: true}} {
		got, err := parseABIDiagnosticRecoveryTrace(test.value)
		if (err != nil) != test.wantErr || got != test.want {
			t.Fatalf("diagnostic trace %d = %t, %v", test.value, got, err)
		}
	}
}

func TestExportedABIValidatesAV1DependencyIdentity(t *testing.T) {
	for _, test := range []struct {
		name                     string
		mode, temporal, template uint8
		keyframe                 bool
		wantErr                  bool
	}{
		{name: "L1T1 key", mode: 1, template: 0, keyframe: true},
		{name: "L1T1 delta", mode: 1, template: 1},
		{name: "L1T2 T0", mode: 2, template: 1},
		{name: "L1T2 T1", mode: 2, temporal: 1, template: 2},
		{name: "L1T3 T0", mode: 3, template: 1},
		{name: "L1T3 T1", mode: 3, temporal: 1, template: 2},
		{name: "L1T3 T2A", mode: 3, temporal: 2, template: 3},
		{name: "L1T3 T2B", mode: 3, temporal: 2, template: 4},
		{name: "missing", wantErr: true},
		{name: "unknown mode", mode: 4, wantErr: true},
		{name: "template outside mode", mode: 1, temporal: 1, template: 2, wantErr: true},
		{name: "wrong temporal", mode: 3, temporal: 2, template: 2, wantErr: true},
		{name: "keyframe nonzero template", mode: 3, temporal: 2, template: 3, keyframe: true, wantErr: true},
		{name: "delta key template", mode: 3, template: 0, wantErr: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			dependency, err := parseABIFrameDependency(
				test.mode, test.temporal, test.template, test.keyframe,
			)
			if test.wantErr {
				if err == nil {
					t.Fatalf("invalid dependency passed: %#v", dependency)
				}
				return
			}
			if err != nil || uint8(dependency.Mode) != test.mode ||
				dependency.TemporalID != test.temporal || dependency.TemplateID != test.template {
				t.Fatalf("dependency = %#v, %v", dependency, err)
			}
		})
	}
}

func TestExportedABIParsesOneStrictImpairmentProfile(t *testing.T) {
	profile := mustRecoveryMatrixProfile(t, "single-original-loss")
	data, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := parseRecoveryImpairment(data, 1741)
	if err != nil {
		t.Fatal(err)
	}
	if parsed == nil || parsed.Profile.Name != profile.Name || parsed.Seed != 1741 {
		t.Fatalf("parsed impairment = %#v", parsed)
	}
	if _, err := parseRecoveryImpairment(append(data, []byte(" true")...), 1741); err == nil {
		t.Fatal("trailing profile value unexpectedly accepted")
	}
	if _, err := parseRecoveryImpairment([]byte(`{"name":"unknown"}`), 1741); err == nil {
		t.Fatal("partial profile unexpectedly accepted")
	}
}

func TestExportedABIInjectsTheSeparateSeedBeforeProbabilisticValidation(t *testing.T) {
	profile := mustRecoveryMatrixProfile(t, "random-loss-1pct")
	profile.Seed = nil
	data, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := parseRecoveryImpairment(data, 8191)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Profile.Seed == nil || *parsed.Profile.Seed != 8191 || parsed.Seed != 8191 {
		t.Fatalf("parsed seeded impairment = %#v", parsed)
	}
}

func TestExportedABIRegistryUsesOpaqueMonotonicHandlesAndIdempotentClose(t *testing.T) {
	registry := newSessionRegistry()
	first := &fakeExportSession{}
	second := &fakeExportSession{}
	firstHandle, err := registry.add(first)
	if err != nil {
		t.Fatal(err)
	}
	secondHandle, err := registry.add(second)
	if err != nil {
		t.Fatal(err)
	}
	if firstHandle == 0 || secondHandle != firstHandle+1 {
		t.Fatalf("handles = %d, %d", firstHandle, secondHandle)
	}
	if got, err := registry.get(firstHandle); err != nil || got != first {
		t.Fatalf("lookup = %v, error = %v", got, err)
	}

	var wait sync.WaitGroup
	for iteration := 0; iteration < 1_000; iteration++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			if err := registry.close(firstHandle); err != nil {
				t.Errorf("concurrent close failed: %v", err)
			}
		}()
	}
	wait.Wait()
	if first.closeCount != 1 {
		t.Fatalf("underlying close count = %d", first.closeCount)
	}
	if _, err := registry.get(firstHandle); err == nil {
		t.Fatal("closed handle unexpectedly resolved")
	}
	finalStats, err := copyRegistryStats(registry, firstHandle)
	if err != nil {
		t.Fatalf("copy final stats: %v", err)
	}
	if !bytes.Contains(finalStats, []byte(`"retainedFramesCurrent":0`)) {
		t.Fatalf("final stats did not reflect completed close: %s", finalStats)
	}
	if err := registry.close(99_999); err == nil {
		t.Fatal("unknown handle close unexpectedly succeeded")
	}
}

func TestExportedABICopiesInputsAndReportsDropAndStats(t *testing.T) {
	registry := newSessionRegistry()
	session := &fakeExportSession{inputDisposition: SendDispositionDropped}
	handle, err := registry.add(session)
	if err != nil {
		t.Fatal(err)
	}
	input := testWireMessage(wireKindPointer, 29)
	disposition, err := sendRegistryInput(registry, handle, input)
	if err != nil || disposition != SendDispositionDropped {
		t.Fatalf("input disposition = %d, error = %v", disposition, err)
	}
	input[0] = 0
	if session.input[0] != 'L' {
		t.Fatal("registry retained caller-owned input bytes")
	}

	stats, err := copyRegistryStats(registry, handle)
	if err != nil {
		t.Fatal(err)
	}
	if !json.Valid(stats) || !bytes.Contains(stats, []byte(`"frameAssemblyCapacity":1`)) ||
		!bytes.Contains(stats, []byte(`"recovery":{"mode":"off"`)) {
		t.Fatalf("stats = %q", stats)
	}
}

type fakeExportSession struct {
	mutex            sync.Mutex
	closeCount       int
	input            []byte
	inputDisposition SendDisposition
}

func (session *fakeExportSession) SendVideo(OutboundFrame) error { return nil }

func (session *fakeExportSession) SendInput(data []byte) (SendDisposition, error) {
	session.mutex.Lock()
	session.input = append([]byte(nil), data...)
	session.mutex.Unlock()
	return session.inputDisposition, nil
}

func (session *fakeExportSession) SendControl([]byte) error { return nil }

func (session *fakeExportSession) Stats() SessionStats {
	session.mutex.Lock()
	closed := session.closeCount > 0
	session.mutex.Unlock()
	retained := uint64(1)
	if closed {
		retained = 0
	}
	return SessionStats{
		FrameAssemblyCapacity: 1,
		ResponderCache: ResponderCacheSnapshot{
			PacketsCurrent: 0, PacketsPeak: 2, BytesCurrent: 0, BytesPeak: 2_400,
		},
		Recovery: SessionRecoveryStats{
			Mode: "off", RTXMaxAgeMilliseconds: 30, PrimaryPayloadType: av1PayloadType,
			RecoverySnapshot: RecoverySnapshot{RetainedFramesCurrent: retained},
		},
	}
}

func (session *fakeExportSession) ActivateImpairment() error         { return nil }
func (session *fakeExportSession) ResetImpairmentMeasurement() error { return nil }
func (session *fakeExportSession) DrainImpairment() error            { return nil }

func (session *fakeExportSession) Close() error {
	session.mutex.Lock()
	session.closeCount++
	session.mutex.Unlock()
	return nil
}

var _ exportedSession = (*fakeExportSession)(nil)
