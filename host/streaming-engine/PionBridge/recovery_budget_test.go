package main

import "testing"

func TestRecoveryBudgetAllocatorConservativeTargets(t *testing.T) {
	tests := []struct {
		name string
		mode AV1ScalabilityMode
		tier FlexFECTier
		want uint32
	}{
		{name: "off", mode: AV1ScalabilityL1T3, tier: FlexFECTierOff, want: 7_600_000},
		{name: "L1T1 low", mode: AV1ScalabilityL1T1, tier: FlexFECTierLow, want: 6_909_090},
		{name: "L1T2 low", mode: AV1ScalabilityL1T2, tier: FlexFECTierLow, want: 7_238_095},
		{name: "L1T3 low", mode: AV1ScalabilityL1T3, tier: FlexFECTierLow, want: 7_414_634},
		{name: "L1T3 medium", mode: AV1ScalabilityL1T3, tier: FlexFECTierMedium, want: 6_909_090},
		{name: "L1T1 high", mode: AV1ScalabilityL1T1, tier: FlexFECTierHigh, want: 5_428_571},
		{name: "L1T2 high", mode: AV1ScalabilityL1T2, tier: FlexFECTierHigh, want: 5_428_571},
		{name: "L1T3 high", mode: AV1ScalabilityL1T3, tier: FlexFECTierHigh, want: 5_428_571},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			allocator, err := NewRecoveryBudgetAllocator(8_000_000, test.mode)
			if err != nil {
				t.Fatal(err)
			}
			if got := allocator.Target(test.tier); got != test.want {
				t.Fatalf("target=%d, want %d", got, test.want)
			}
		})
	}
}

func TestRecoveryBudgetAllocatorRefinesFromRollingRecoveryRate(t *testing.T) {
	allocator, err := NewRecoveryBudgetAllocator(8_000_000, AV1ScalabilityL1T3)
	if err != nil {
		t.Fatal(err)
	}
	allocator.Observe(RTPRateObservation{
		MediaBitsPerSecond: 7_000_000,
		FECBitsPerSecond:   600_000,
		RTXBitsPerSecond:   400_000,
	})
	if got := allocator.Target(FlexFECTierMedium); got != 6_909_090 {
		t.Fatalf("refined target=%d, want 6909090", got)
	}
	allocator.AcceptTarget(6_909_090)
	snapshot := allocator.Snapshot()
	if snapshot.RecoveryBitsPerSecondEWMA != 1_000_000 ||
		snapshot.MediaBitsPerSecond != 7_000_000 ||
		snapshot.FECBitsPerSecond != 600_000 ||
		snapshot.RTXBitsPerSecond != 400_000 || snapshot.ObservationCount != 1 ||
		snapshot.ConservativeCeilingBitsPerSecond != 6_909_090 ||
		snapshot.MediaTargetBitsPerSecond != 6_909_090 {
		t.Fatalf("unexpected snapshot: %+v", snapshot)
	}

	allocator.Observe(RTPRateObservation{})
	if got := allocator.Target(FlexFECTierMedium); got != 6_909_090 {
		t.Fatalf("four-window EWMA medium target=%d, want 6909090", got)
	}
	if got := allocator.Target(FlexFECTierOff); got != 7_250_000 {
		t.Fatalf("off target=%d, want 7250000", got)
	}
}

func TestRecoveryBudgetAllocatorAccountsForMediaRTPOverheadAndCurrentBurst(t *testing.T) {
	allocator, err := NewRecoveryBudgetAllocator(8_000_000, AV1ScalabilityL1T3)
	if err != nil {
		t.Fatal(err)
	}
	if got := allocator.Target(FlexFECTierOff); got != 7_600_000 {
		t.Fatalf("initial off target=%d", got)
	}
	allocator.AcceptTarget(7_600_000)
	allocator.Observe(RTPRateObservation{MediaBitsPerSecond: 8_800_000})
	if got := allocator.Target(FlexFECTierOff); got != 6_909_090 {
		t.Fatalf("RTP-overhead target=%d, want 6909090", got)
	}
	allocator.AcceptTarget(6_909_090)
	allocator.Observe(RTPRateObservation{
		MediaBitsPerSecond: 6_000_000,
		FECBitsPerSecond:   1_000_000,
		RTXBitsPerSecond:   3_000_000,
	})
	if got := allocator.Target(FlexFECTierMedium); got != 4_606_060 {
		t.Fatalf("burst-compensated target=%d, want 4606060", got)
	}
}

func TestRecoveryBudgetAllocatorClampsAndRejectsInvalidConfiguration(t *testing.T) {
	if _, err := NewRecoveryBudgetAllocator(0, AV1ScalabilityL1T3); err == nil {
		t.Fatal("expected zero budget to fail")
	}
	if _, err := NewRecoveryBudgetAllocator(8_000_000, 0); err == nil {
		t.Fatal("expected invalid scalability mode to fail")
	}
	allocator, err := NewRecoveryBudgetAllocator(8_000_000, AV1ScalabilityL1T3)
	if err != nil {
		t.Fatal(err)
	}
	allocator.Observe(RTPRateObservation{
		FECBitsPerSecond: 5_000_000, RTXBitsPerSecond: 5_000_000,
	})
	if got := allocator.Target(FlexFECTierHigh); got != 2_000_000 {
		t.Fatalf("clamped target=%d, want 2000000", got)
	}
	if got := allocator.Target(FlexFECTier(255)); got != 0 {
		t.Fatalf("invalid tier target=%d, want 0", got)
	}
}

func TestRecoveryBudgetAllocatorEWMADoesNotOverflow(t *testing.T) {
	allocator, err := NewRecoveryBudgetAllocator(8_000_000, AV1ScalabilityL1T3)
	if err != nil {
		t.Fatal(err)
	}
	maximumValue := ^uint64(0)
	maximum := RTPRateObservation{
		FECBitsPerSecond: maximumValue,
		RTXBitsPerSecond: maximumValue,
	}
	allocator.Observe(maximum)
	allocator.Observe(maximum)
	if got := allocator.Snapshot().RecoveryBitsPerSecondEWMA; got != maximumValue {
		t.Fatalf("overflowed EWMA=%d, want %d", got, maximumValue)
	}
}
