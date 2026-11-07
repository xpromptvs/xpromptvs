package main

import (
	"math"
	"sync"
	"testing"
	"time"
)

func TestRTXAgePolicyFixedIgnoresRTTAndNormalizesIdentity(t *testing.T) {
	estimator := &mediaRTTEstimator{}
	if !estimator.Observe(250 * time.Millisecond) {
		t.Fatal("media RTT sample was rejected")
	}
	policy, err := NewRTXAgePolicy(RTXAgePolicyConfig{
		Mode: RTXAgeFixed, Floor: 75 * time.Millisecond,
	}, estimator)
	if err != nil {
		t.Fatal(err)
	}
	if got := policy.EffectiveMaxAge(); got != 75*time.Millisecond {
		t.Fatalf("effective fixed age = %v, want 75ms", got)
	}
	if !estimator.Observe(500 * time.Millisecond) {
		t.Fatal("second media RTT sample was rejected")
	}
	if got := policy.EffectiveMaxAge(); got != 75*time.Millisecond {
		t.Fatalf("effective fixed age after RTT change = %v, want 75ms", got)
	}
	if got := policy.NegotiatedRTXTime(); got != 75*time.Millisecond {
		t.Fatalf("negotiated fixed age = %v, want 75ms", got)
	}
	snapshot := policy.Snapshot()
	if snapshot.Mode != "fixed" ||
		snapshot.FloorMilliseconds != 75 ||
		snapshot.CapMilliseconds != 75 ||
		snapshot.MultiplierMilli != 1_000 ||
		snapshot.HasMediaRTT ||
		snapshot.EffectiveMaxAgeMilliseconds != 75 ||
		snapshot.EffectiveThresholdSampleCount != 2 ||
		snapshot.EffectiveThresholdMinimumMilliseconds != 75 ||
		snapshot.EffectiveThresholdMaximumMilliseconds != 75 {
		t.Fatalf("unexpected fixed snapshot: %#v", snapshot)
	}
}

func TestRTXAgePolicyRTTUsesFallbackFloorAndExactClamps(t *testing.T) {
	estimator := &mediaRTTEstimator{}
	policy, err := NewRTXAgePolicy(RTXAgePolicyConfig{
		Mode: RTXAgeRTT, Floor: 30 * time.Millisecond,
		Cap: 500 * time.Millisecond, MultiplierMilli: 1_250,
	}, estimator)
	if err != nil {
		t.Fatal(err)
	}
	if got := policy.EffectiveMaxAge(); got != 30*time.Millisecond {
		t.Fatalf("startup age = %v, want 30ms", got)
	}
	if got := policy.NegotiatedRTXTime(); got != 500*time.Millisecond {
		t.Fatalf("negotiated RTT age = %v, want 500ms", got)
	}
	tests := []struct {
		rtt  time.Duration
		want time.Duration
	}{
		{80 * time.Millisecond, 100 * time.Millisecond},
		{10 * time.Millisecond, 30 * time.Millisecond},
		{600 * time.Millisecond, 500 * time.Millisecond},
		{33_333_333 * time.Nanosecond, 41_666_666 * time.Nanosecond},
	}
	for _, test := range tests {
		if !estimator.Observe(test.rtt) {
			t.Fatalf("media RTT sample %v was rejected", test.rtt)
		}
		if got := policy.EffectiveMaxAge(); got != test.want {
			t.Fatalf("effective age for RTT %v = %v, want %v", test.rtt, got, test.want)
		}
	}
	snapshot := policy.Snapshot()
	if !snapshot.HasMediaRTT ||
		snapshot.CurrentMediaRTTMicroseconds != 33_333 ||
		snapshot.EffectiveMaxAgeMilliseconds != 41 ||
		snapshot.EffectiveThresholdSampleCount != 5 ||
		snapshot.EffectiveThresholdMinimumMilliseconds != 30 ||
		snapshot.EffectiveThresholdMaximumMilliseconds != 500 {
		t.Fatalf("unexpected RTT snapshot: %#v", snapshot)
	}
}

func TestRTXAgePolicyAvoidsIntermediateMultiplicationOverflow(t *testing.T) {
	estimator := &mediaRTTEstimator{}
	if !estimator.Observe(maximumObservedMediaRTT) {
		t.Fatal("maximum media RTT sample was rejected")
	}
	policy, err := NewRTXAgePolicy(RTXAgePolicyConfig{
		Mode: RTXAgeRTT, Floor: time.Millisecond,
		Cap: time.Second, MultiplierMilli: math.MaxUint32,
	}, estimator)
	if err != nil {
		t.Fatal(err)
	}
	if got := policy.EffectiveMaxAge(); got != time.Second {
		t.Fatalf("overflow-safe effective age = %v, want 1s cap", got)
	}
}

func TestRTXAgePolicyRejectsInvalidConfigurations(t *testing.T) {
	estimator := &mediaRTTEstimator{}
	tests := []RTXAgePolicyConfig{
		{},
		{Mode: RTXAgeMode(99), Floor: 30 * time.Millisecond},
		{Mode: RTXAgeFixed, Floor: 0},
		{Mode: RTXAgeFixed, Floor: time.Microsecond},
		{Mode: RTXAgeFixed, Floor: 30*time.Millisecond + time.Microsecond},
		{Mode: RTXAgeFixed, Floor: time.Second + time.Millisecond},
		{Mode: RTXAgeFixed, Floor: 30 * time.Millisecond, Cap: 31 * time.Millisecond},
		{Mode: RTXAgeFixed, Floor: 30 * time.Millisecond, MultiplierMilli: 999},
		{Mode: RTXAgeRTT, Floor: 30 * time.Millisecond, Cap: 500 * time.Millisecond},
		{Mode: RTXAgeRTT, Floor: 30 * time.Millisecond, Cap: 29 * time.Millisecond, MultiplierMilli: 1_000},
		{Mode: RTXAgeRTT, Floor: 30 * time.Millisecond, Cap: time.Second + time.Millisecond, MultiplierMilli: 1_000},
	}
	for _, config := range tests {
		if _, err := NewRTXAgePolicy(config, estimator); err == nil {
			t.Fatalf("invalid config was accepted: %#v", config)
		}
	}
	if _, err := NewRTXAgePolicy(RTXAgePolicyConfig{
		Mode: RTXAgeRTT, Floor: 30 * time.Millisecond,
		Cap: 500 * time.Millisecond, MultiplierMilli: 1_000,
	}, nil); err == nil {
		t.Fatal("RTT policy accepted nil media RTT estimator")
	}
}

func TestRTXAgePolicySupportsConcurrentThresholdSnapshots(t *testing.T) {
	estimator := &mediaRTTEstimator{}
	policy, err := NewRTXAgePolicy(RTXAgePolicyConfig{
		Mode: RTXAgeRTT, Floor: 30 * time.Millisecond,
		Cap: 500 * time.Millisecond, MultiplierMilli: 1_500,
	}, estimator)
	if err != nil {
		t.Fatal(err)
	}
	var workers sync.WaitGroup
	for worker := range 8 {
		workers.Add(1)
		go func(offset int) {
			defer workers.Done()
			for sample := range 1_000 {
				estimator.Observe(time.Duration(30+offset+sample%300) * time.Millisecond)
				age := policy.EffectiveMaxAge()
				if age < 30*time.Millisecond || age > 500*time.Millisecond {
					t.Errorf("concurrent effective age out of range: %v", age)
					return
				}
				_ = policy.Snapshot()
			}
		}(worker)
	}
	workers.Wait()
	snapshot := policy.Snapshot()
	if snapshot.EffectiveThresholdSampleCount != 8_000 ||
		snapshot.EffectiveThresholdMinimumMilliseconds < 30 ||
		snapshot.EffectiveThresholdMaximumMilliseconds > 500 {
		t.Fatalf("unexpected concurrent snapshot: %#v", snapshot)
	}
}
