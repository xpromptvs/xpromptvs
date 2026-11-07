package main

import (
	"math"
	"math/rand"
	"sync"
	"testing"
	"time"
)

func TestRecoveryFrameClockBudgetCarriesExactFrameCredit(t *testing.T) {
	budget, err := NewRecoveryFrameClockBudget(RecoveryFrameClockBudgetConfig{
		RateBitsPerSecond: 8_000_000,
		FramesPerSecond:   60,
		BurstDuration:     20 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	for frameID := uint64(41); frameID < 101; frameID++ {
		if err := budget.AdvanceFrame(frameID); err != nil {
			t.Fatal(err)
		}
	}
	snapshot := budget.Snapshot()
	if snapshot.FramesAdvanced != 60 || snapshot.CreditBitsEarned != 8_000_000 {
		t.Fatalf("unexpected exact credit: %#v", snapshot)
	}
	if snapshot.BurstCapacityBits != 160_000 ||
		snapshot.AvailableCreditBits != 160_000 {
		t.Fatalf("unexpected cap: %#v", snapshot)
	}
	if snapshot.CreditBitsDiscardedAtCap != 8_000_000 {
		t.Fatalf("discarded credit = %d", snapshot.CreditBitsDiscardedAtCap)
	}
	if snapshot.LedgerVersion != recoveryFrameClockBudgetVersion ||
		snapshot.FirstFrameID == nil || *snapshot.FirstFrameID != 41 ||
		snapshot.LastFrameID == nil || *snapshot.LastFrameID != 100 {
		t.Fatalf("unexpected identity: %#v", snapshot)
	}
}

func TestRecoveryFrameClockBudgetRejectsNonconsecutiveFramesWithoutGrantingCredit(t *testing.T) {
	budget, err := NewRecoveryFrameClockBudget(RecoveryFrameClockBudgetConfig{
		RateBitsPerSecond: 8_000_000,
		FramesPerSecond:   60,
		BurstDuration:     20 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := budget.AdvanceFrame(10); err != nil {
		t.Fatal(err)
	}
	before := budget.Snapshot()
	for _, frameID := range []uint64{10, 9, 12} {
		if err := budget.AdvanceFrame(frameID); err == nil {
			t.Fatalf("accepted invalid frame ID %d", frameID)
		}
	}
	after := budget.Snapshot()
	if after.InvalidFrameProgressions != 3 ||
		after.FramesAdvanced != before.FramesAdvanced ||
		after.CreditBitsEarned != before.CreditBitsEarned ||
		after.LastFrameID == nil || *after.LastFrameID != 10 {
		t.Fatalf("invalid progression mutated credit: before=%#v after=%#v", before, after)
	}
	if err := budget.AdvanceFrame(11); err != nil {
		t.Fatalf("valid successor rejected: %v", err)
	}
}

func TestRecoveryFrameClockBudgetRejectsInvalidConfiguration(t *testing.T) {
	for _, configuration := range []RecoveryFrameClockBudgetConfig{
		{},
		{RateBitsPerSecond: 8_000_000, FramesPerSecond: 60},
		{RateBitsPerSecond: 8_000_000, BurstDuration: 20 * time.Millisecond},
		{FramesPerSecond: 60, BurstDuration: 20 * time.Millisecond},
		{RateBitsPerSecond: 8_000_000, FramesPerSecond: 60, BurstDuration: 101 * time.Millisecond},
	} {
		if _, err := NewRecoveryFrameClockBudget(configuration); err == nil {
			t.Fatalf("accepted invalid configuration: %#v", configuration)
		}
	}
}

func TestRecoveryFrameClockBudgetSharesCreditAcrossRTXAndFEC(t *testing.T) {
	budget, err := NewRecoveryFrameClockBudget(RecoveryFrameClockBudgetConfig{
		RateBitsPerSecond: 8_000_000,
		FramesPerSecond:   60,
		BurstDuration:     20 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := budget.AdvanceFrame(1); err != nil {
		t.Fatal(err)
	}
	if err := budget.ObserveMedia(20_000); err != nil {
		t.Fatal(err)
	}
	if admitted, err := budget.TryAdmitRecovery(TWCCRTX, 1); err != nil || admitted {
		t.Fatalf("RTX at zero credit = %v, %v", admitted, err)
	}
	if err := budget.AdvanceFrame(2); err != nil {
		t.Fatal(err)
	}
	if admitted, err := budget.TryAdmitRecovery(TWCCRTX, 16_666); err != nil || !admitted {
		t.Fatalf("exact shared RTX admission = %v, %v", admitted, err)
	}
	if admitted, err := budget.TryAdmitRecovery(TWCCFEC, 1); err != nil || admitted {
		t.Fatalf("FEC beyond shared balance = %v, %v", admitted, err)
	}
	snapshot := budget.Snapshot()
	if snapshot.AvailableCreditBits != 5 ||
		snapshot.MediaPackets != 1 || snapshot.MediaBytes != 20_000 ||
		snapshot.RTXAdmittedPackets != 1 || snapshot.RTXAdmittedBytes != 16_666 ||
		snapshot.RTXSuppressedPackets != 1 || snapshot.RTXSuppressedBytes != 1 ||
		snapshot.FECAdmittedPackets != 0 || snapshot.FECAdmittedBytes != 0 ||
		snapshot.FECSuppressedPackets != 1 || snapshot.FECSuppressedBytes != 1 {
		t.Fatalf("unexpected shared-credit snapshot: %#v", snapshot)
	}
}

func TestRecoveryFrameClockBudgetNeverRejectsMediaAndRepaysExactDebt(t *testing.T) {
	budget, err := NewRecoveryFrameClockBudget(RecoveryFrameClockBudgetConfig{
		RateBitsPerSecond: 8_000_000,
		FramesPerSecond:   60,
		BurstDuration:     20 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := budget.AdvanceFrame(7); err != nil {
		t.Fatal(err)
	}
	if err := budget.ObserveMedia(40_000); err != nil {
		t.Fatalf("large media was rejected: %v", err)
	}
	if got := budget.Snapshot(); got.AvailableCreditBits != -160_000 ||
		got.MaximumMediaDebtBits != 160_000 || got.MediaOnlyViolationCount != 1 {
		t.Fatalf("unexpected media debt: %#v", got)
	}
	if err := budget.AdvanceFrame(8); err != nil {
		t.Fatal(err)
	}
	if admitted, err := budget.TryAdmitRecovery(TWCCRTX, 1); err != nil || admitted {
		t.Fatalf("RTX while in debt = %v, %v", admitted, err)
	}
	if err := budget.AdvanceFrame(9); err != nil {
		t.Fatal(err)
	}
	if admitted, err := budget.TryAdmitRecovery(TWCCFEC, 13_333); err != nil || !admitted {
		t.Fatalf("FEC after debt repayment = %v, %v", admitted, err)
	}
	if got := budget.Snapshot().AvailableCreditBits; got != 3 {
		t.Fatalf("remaining credit = %d", got)
	}
}

func TestRecoveryFrameClockBudgetRejectsPacketsBeforeFirstFrameAndInvalidSizes(t *testing.T) {
	budget, err := NewRecoveryFrameClockBudget(RecoveryFrameClockBudgetConfig{
		RateBitsPerSecond: 8_000_000,
		FramesPerSecond:   60,
		BurstDuration:     20 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := budget.ObserveMedia(1); err == nil {
		t.Fatal("media before first frame was accepted")
	}
	if admitted, err := budget.TryAdmitRecovery(TWCCRTX, 1); err == nil || admitted {
		t.Fatalf("recovery before first frame = %v, %v", admitted, err)
	}
	if err := budget.AdvanceFrame(1); err != nil {
		t.Fatal(err)
	}
	if err := budget.ObserveMedia(0); err == nil {
		t.Fatal("empty media packet was accepted")
	}
	for _, class := range []TWCCPacketClass{TWCCMedia, "unknown"} {
		if admitted, err := budget.TryAdmitRecovery(class, 1); err == nil || admitted {
			t.Fatalf("invalid recovery class %q = %v, %v", class, admitted, err)
		}
	}
	if admitted, err := budget.TryAdmitRecovery(TWCCRTX, 0); err == nil || admitted {
		t.Fatalf("empty RTX = %v, %v", admitted, err)
	}
}

func TestRecoveryFrameClockBudgetRecordsExactPrefixAndSlidingMargins(t *testing.T) {
	budget, err := NewRecoveryFrameClockBudget(RecoveryFrameClockBudgetConfig{
		RateBitsPerSecond: 8_000,
		FramesPerSecond:   60,
		BurstDuration:     20 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	for frameID := uint64(1); frameID <= 300; frameID++ {
		if err := budget.AdvanceFrame(frameID); err != nil {
			t.Fatal(err)
		}
		if err := budget.ObserveMedia(16); err != nil {
			t.Fatal(err)
		}
	}
	snapshot := budget.Snapshot()
	expected := map[string]RecoveryFrameClockWindowSnapshot{
		"prefix": {
			WindowFrames: 1, FirstFrameID: 1, LastFrameID: 1,
			EarnedBits: 133, AdmittedBits: 128, MediaBits: 128,
			MarginBits: 165,
		},
		"60": {
			WindowFrames: 60, FirstFrameID: 1, LastFrameID: 60,
			EarnedBits: 8_000, AdmittedBits: 7_680, MediaBits: 7_680,
			MarginBits: 480,
		},
		"120": {
			WindowFrames: 120, FirstFrameID: 1, LastFrameID: 120,
			EarnedBits: 16_000, AdmittedBits: 15_360, MediaBits: 15_360,
			MarginBits: 800,
		},
		"300": {
			WindowFrames: 300, FirstFrameID: 1, LastFrameID: 300,
			EarnedBits: 40_000, AdmittedBits: 38_400, MediaBits: 38_400,
			MarginBits: 1_760,
		},
	}
	for key, want := range expected {
		if got, exists := snapshot.WorstMargins[key]; !exists || got != want {
			t.Fatalf("worst margin %q = %#v, exists=%v, want %#v", key, got, exists, want)
		}
	}
	if snapshot.MediaOnlyViolationCount != 0 {
		t.Fatalf("clean media violated budget: %#v", snapshot)
	}
}

func TestRecoveryFrameClockBudgetDoesNotEarnCreditWithoutFrameAdvance(t *testing.T) {
	budget, err := NewRecoveryFrameClockBudget(RecoveryFrameClockBudgetConfig{
		RateBitsPerSecond: 8_000_000,
		FramesPerSecond:   60,
		BurstDuration:     20 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := budget.AdvanceFrame(1); err != nil {
		t.Fatal(err)
	}
	if err := budget.ObserveMedia(20_000); err != nil {
		t.Fatal(err)
	}
	before := budget.Snapshot()
	for index := 0; index < 100; index++ {
		_ = budget.Snapshot()
	}
	after := budget.Snapshot()
	if after.AvailableCreditBits != before.AvailableCreditBits ||
		after.CreditBitsEarned != before.CreditBitsEarned ||
		after.FramesAdvanced != before.FramesAdvanced {
		t.Fatalf("pause created credit: before=%#v after=%#v", before, after)
	}
}

func TestRecoveryFrameClockBudgetKeepsFullPrefixAfterRollingHistoryWraps(t *testing.T) {
	budget, err := NewRecoveryFrameClockBudget(RecoveryFrameClockBudgetConfig{
		RateBitsPerSecond: 8_000,
		FramesPerSecond:   60,
		BurstDuration:     20 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	for frameID := uint64(1); frameID <= 1_000; frameID++ {
		if err := budget.AdvanceFrame(frameID); err != nil {
			t.Fatal(err)
		}
		if err := budget.ObserveMedia(16); err != nil {
			t.Fatal(err)
		}
	}
	if err := budget.ObserveMedia(20_000); err != nil {
		t.Fatal(err)
	}
	prefix := budget.Snapshot().WorstMargins["prefix"]
	if prefix.FirstFrameID != 1 || prefix.LastFrameID != 1_000 || prefix.WindowFrames != 1_000 {
		t.Fatalf("invalid retained prefix identity: %#v", prefix)
	}
}

func TestRecoveryFrameClockBudgetMatchesDeterministicReference(t *testing.T) {
	const rate = uint64(8_000_000)
	const fps = uint64(60)
	const capacity = int64(160_000)
	budget, err := NewRecoveryFrameClockBudget(RecoveryFrameClockBudgetConfig{
		RateBitsPerSecond: uint32(rate),
		FramesPerSecond:   uint32(fps),
		BurstDuration:     20 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	random := rand.New(rand.NewSource(1741))
	balance := capacity
	remainder := uint64(0)
	frameID := uint64(900)
	var mediaBytes, admittedRTXBytes, admittedFECBytes uint64
	var suppressedRTXBytes, suppressedFECBytes uint64
	for operation := 0; operation < 10_000; operation++ {
		switch random.Intn(5) {
		case 0:
			frameID++
			if err := budget.AdvanceFrame(frameID); err != nil {
				t.Fatal(err)
			}
			credit := rate / fps
			remainder += rate % fps
			credit += remainder / fps
			remainder %= fps
			balance += int64(credit)
			if balance > capacity {
				balance = capacity
			}
		case 1, 2:
			if budget.Snapshot().FramesAdvanced == 0 {
				continue
			}
			packetBytes := random.Intn(1_400) + 1
			if err := budget.ObserveMedia(packetBytes); err != nil {
				t.Fatal(err)
			}
			balance -= int64(packetBytes * 8)
			mediaBytes += uint64(packetBytes)
		case 3, 4:
			if budget.Snapshot().FramesAdvanced == 0 {
				continue
			}
			packetBytes := random.Intn(1_400) + 1
			class := TWCCRTX
			if operation%2 == 0 {
				class = TWCCFEC
			}
			wantAdmitted := balance >= int64(packetBytes*8)
			gotAdmitted, err := budget.TryAdmitRecovery(class, packetBytes)
			if err != nil || gotAdmitted != wantAdmitted {
				t.Fatalf("operation %d admission = %v, %v; want %v", operation, gotAdmitted, err, wantAdmitted)
			}
			if gotAdmitted {
				balance -= int64(packetBytes * 8)
				if class == TWCCRTX {
					admittedRTXBytes += uint64(packetBytes)
				} else {
					admittedFECBytes += uint64(packetBytes)
				}
			} else if class == TWCCRTX {
				suppressedRTXBytes += uint64(packetBytes)
			} else {
				suppressedFECBytes += uint64(packetBytes)
			}
		}
	}
	snapshot := budget.Snapshot()
	if snapshot.AvailableCreditBits != balance || snapshot.MediaBytes != mediaBytes ||
		snapshot.RTXAdmittedBytes != admittedRTXBytes || snapshot.FECAdmittedBytes != admittedFECBytes ||
		snapshot.RTXSuppressedBytes != suppressedRTXBytes || snapshot.FECSuppressedBytes != suppressedFECBytes {
		t.Fatalf("ledger/reference mismatch: %#v", snapshot)
	}
}

func TestRecoveryFrameClockBudgetSerializesConcurrentRecoveryAdmissions(t *testing.T) {
	budget, err := NewRecoveryFrameClockBudget(RecoveryFrameClockBudgetConfig{
		RateBitsPerSecond: 8_000,
		FramesPerSecond:   60,
		BurstDuration:     20 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := budget.AdvanceFrame(1); err != nil {
		t.Fatal(err)
	}
	const attempts = 1_000
	var wait sync.WaitGroup
	wait.Add(attempts)
	for index := 0; index < attempts; index++ {
		go func(class TWCCPacketClass) {
			defer wait.Done()
			if _, err := budget.TryAdmitRecovery(class, 1); err != nil {
				t.Errorf("concurrent admission: %v", err)
			}
		}(map[bool]TWCCPacketClass{true: TWCCRTX, false: TWCCFEC}[index%2 == 0])
	}
	wait.Wait()
	snapshot := budget.Snapshot()
	if admitted := snapshot.RTXAdmittedPackets + snapshot.FECAdmittedPackets; admitted != 20 {
		t.Fatalf("admitted packets = %d, want 20 from the capped 160-bit balance", admitted)
	}
	if snapshot.AvailableCreditBits != 0 {
		t.Fatalf("remaining credit = %d", snapshot.AvailableCreditBits)
	}
}

func TestRecoveryFrameClockBudgetRejectsCounterOverflowWithoutPacketMutation(t *testing.T) {
	budget, err := NewRecoveryFrameClockBudget(RecoveryFrameClockBudgetConfig{
		RateBitsPerSecond: 8_000_000,
		FramesPerSecond:   60,
		BurstDuration:     20 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := budget.AdvanceFrame(1); err != nil {
		t.Fatal(err)
	}
	budget.mutex.Lock()
	budget.totalAdmittedBits = math.MaxUint64
	budget.mutex.Unlock()
	before := budget.Snapshot()
	if admitted, err := budget.TryAdmitRecovery(TWCCRTX, 1); err == nil || admitted {
		t.Fatalf("overflowing recovery = %v, %v", admitted, err)
	}
	after := budget.Snapshot()
	if after.AvailableCreditBits != before.AvailableCreditBits ||
		after.RTXAdmittedPackets != before.RTXAdmittedPackets ||
		after.RTXAdmittedBytes != before.RTXAdmittedBytes {
		t.Fatalf("overflow mutated packet accounting: before=%#v after=%#v", before, after)
	}
}

func TestRecoveryFrameClockBudgetRejectsFrameCreditOverflowWithoutAdvancing(t *testing.T) {
	budget, err := NewRecoveryFrameClockBudget(RecoveryFrameClockBudgetConfig{
		RateBitsPerSecond: 8_000_000,
		FramesPerSecond:   60,
		BurstDuration:     20 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := budget.AdvanceFrame(1); err != nil {
		t.Fatal(err)
	}
	budget.mutex.Lock()
	budget.creditBitsEarned = math.MaxUint64
	budget.mutex.Unlock()
	before := budget.Snapshot()
	if err := budget.AdvanceFrame(2); err == nil {
		t.Fatal("overflowing frame credit was accepted")
	}
	after := budget.Snapshot()
	if after.FramesAdvanced != before.FramesAdvanced ||
		after.LastFrameID == nil || before.LastFrameID == nil ||
		*after.LastFrameID != *before.LastFrameID ||
		after.CreditBitsEarned != before.CreditBitsEarned ||
		after.AvailableCreditBits != before.AvailableCreditBits {
		t.Fatalf("overflow advanced frame state: before=%#v after=%#v", before, after)
	}
}

func TestRecoveryFrameClockBudgetRejectsDiscardedCreditOverflowWithoutAdvancing(t *testing.T) {
	budget, err := NewRecoveryFrameClockBudget(RecoveryFrameClockBudgetConfig{
		RateBitsPerSecond: 8_000_000,
		FramesPerSecond:   60,
		BurstDuration:     20 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := budget.AdvanceFrame(1); err != nil {
		t.Fatal(err)
	}
	budget.mutex.Lock()
	budget.discardedCreditBits = math.MaxUint64
	budget.mutex.Unlock()
	before := budget.Snapshot()
	if err := budget.AdvanceFrame(2); err == nil {
		t.Fatal("overflowing discarded-credit counter was accepted")
	}
	after := budget.Snapshot()
	if after.FramesAdvanced != before.FramesAdvanced ||
		after.LastFrameID == nil || before.LastFrameID == nil ||
		*after.LastFrameID != *before.LastFrameID ||
		after.CreditBitsDiscardedAtCap != before.CreditBitsDiscardedAtCap {
		t.Fatalf("discard overflow advanced frame state: before=%#v after=%#v", before, after)
	}
}
