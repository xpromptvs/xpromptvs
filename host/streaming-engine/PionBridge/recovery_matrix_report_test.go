package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"testing"
	"time"
)

const (
	matrixStatusPass    = "pass"
	matrixStatusFail    = "fail"
	matrixStatusInvalid = "invalid"
)

type recoveryMatrixLatencySummary struct {
	SampleCount         int     `json:"sampleCount"`
	MinimumMilliseconds float64 `json:"minimumMilliseconds"`
	P50Milliseconds     float64 `json:"p50Milliseconds"`
	P95Milliseconds     float64 `json:"p95Milliseconds"`
	P99Milliseconds     float64 `json:"p99Milliseconds"`
	MaximumMilliseconds float64 `json:"maximumMilliseconds"`
}

type recoveryMatrixAssertion struct {
	Name   string `json:"name"`
	Passed bool   `json:"passed"`
	Detail string `json:"detail"`
}

type recoveryMatrixMetrics struct {
	Recovery                       RecoverySnapshot             `json:"recovery"`
	ResponderCache                 ResponderCacheSnapshot       `json:"responderCache"`
	Impairment                     recoveryImpairmentSnapshot   `json:"impairment"`
	FramesSubmitted                uint64                       `json:"framesSubmitted"`
	FramesCompleted                uint64                       `json:"framesCompleted"`
	FramesExpired                  uint64                       `json:"framesExpired"`
	FramesAbandoned                uint64                       `json:"framesAbandoned"`
	FramesResumedAfterRecovery     uint64                       `json:"framesResumedAfterRecovery"`
	CompletedFrameIDs              []uint64                     `json:"completedFrameIds"`
	KeyframeFrameIDs               []uint64                     `json:"keyframeFrameIds"`
	SubmissionToAssembly           recoveryMatrixLatencySummary `json:"submissionToAssembly"`
	RecoveryResolution             recoveryMatrixLatencySummary `json:"recoveryResolution"`
	CompletedFrameInterarrival     recoveryMatrixLatencySummary `json:"completedFrameInterarrival"`
	LongestFreezeProxyMilliseconds float64                      `json:"longestFreezeProxyMilliseconds"`
	RTXToOriginalByteRatio         float64                      `json:"rtxToOriginalByteRatio"`
	SyntheticKeyframeExcessBytes   uint64                       `json:"syntheticKeyframeExcessBytes"`
	ShutdownComplete               bool                         `json:"shutdownComplete"`
}

type recoveryMatrixScenarioResult struct {
	Name            string                    `json:"name"`
	Seed            int64                     `json:"seed"`
	Status          string                    `json:"status"`
	ExpectedOutcome string                    `json:"expectedOutcome"`
	ActualOutcome   string                    `json:"actualOutcome"`
	Profile         recoveryMatrixProfile     `json:"profile"`
	Assertions      []recoveryMatrixAssertion `json:"assertions"`
	Metrics         recoveryMatrixMetrics     `json:"metrics"`
	Error           string                    `json:"error,omitempty"`
}

type recoveryMatrixReport struct {
	SchemaVersion        int                            `json:"schemaVersion"`
	CatalogSchemaVersion int                            `json:"catalogSchemaVersion"`
	Parallelism          int                            `json:"parallelism"`
	SourceRevision       string                         `json:"sourceRevision"`
	SourceDirty          bool                           `json:"sourceDirty"`
	GoVersion            string                         `json:"goVersion"`
	PionWebRTCVersion    string                         `json:"pionWebRTCVersion"`
	PionTransportVersion string                         `json:"pionTransportVersion"`
	Tier                 recoveryMatrixTier             `json:"tier"`
	StartedAtUTC         string                         `json:"startedAtUtc"`
	FinishedAtUTC        string                         `json:"finishedAtUtc"`
	CatalogSHA256        string                         `json:"catalogSha256"`
	HostDescription      string                         `json:"hostDescription"`
	Command              []string                       `json:"command"`
	Results              []recoveryMatrixScenarioResult `json:"results"`
}

func summarizeRecoveryMatrixDurations(samples []time.Duration) recoveryMatrixLatencySummary {
	if len(samples) == 0 {
		return recoveryMatrixLatencySummary{}
	}
	sorted := append([]time.Duration(nil), samples...)
	slices.Sort(sorted)
	milliseconds := func(value time.Duration) float64 {
		return float64(value) / float64(time.Millisecond)
	}
	nearestRank := func(percentile float64) float64 {
		rank := int(math.Ceil(percentile*float64(len(sorted)))) - 1
		if rank < 0 {
			rank = 0
		}
		return milliseconds(sorted[rank])
	}
	return recoveryMatrixLatencySummary{
		SampleCount:         len(sorted),
		MinimumMilliseconds: milliseconds(sorted[0]),
		P50Milliseconds:     nearestRank(0.50),
		P95Milliseconds:     nearestRank(0.95),
		P99Milliseconds:     nearestRank(0.99),
		MaximumMilliseconds: milliseconds(sorted[len(sorted)-1]),
	}
}

func evaluateRecoveryMatrixResult(result recoveryMatrixScenarioResult) recoveryMatrixScenarioResult {
	result.Assertions = nil
	invalid := false
	fail := false
	add := func(name string, passed bool, detail string) {
		result.Assertions = append(result.Assertions, recoveryMatrixAssertion{
			Name: name, Passed: passed, Detail: detail,
		})
		if !passed {
			fail = true
		}
	}
	addInvalid := func(name string, passed bool, detail string) {
		result.Assertions = append(result.Assertions, recoveryMatrixAssertion{
			Name: name, Passed: passed, Detail: detail,
		})
		if !passed {
			invalid = true
		}
	}

	addInvalid("execution-valid", result.Error == "", matrixExecutionDetail(result.Error))
	addInvalid(
		"scheduler-drained", result.Metrics.Impairment.ScheduledBytesCurrent == 0,
		fmt.Sprintf("scheduledBytesCurrent=%d", result.Metrics.Impairment.ScheduledBytesCurrent),
	)
	accountingOK, accountingDetail := recoveryMatrixAccountingReconciled(result.Metrics.Impairment)
	addInvalid("accounting-reconciled", accountingOK, accountingDetail)

	for _, invariant := range result.Profile.RequiredInvariants {
		switch invariant {
		case "clean":
			passed := recoveryMatrixCountersAreClean(result.Metrics.Recovery)
			add(invariant, passed, fmt.Sprintf(
				"nackSent=%d nackReceived=%d rtxSent=%d repaired=%d",
				result.Metrics.Recovery.NACKPacketsSent, result.Metrics.Recovery.NACKPacketsReceived,
				result.Metrics.Recovery.RTXPacketsSent, result.Metrics.Recovery.PacketsRepaired,
			))
		case "rtx-repair":
			passed := result.Metrics.Recovery.RTXPacketsSent > 0 && result.Metrics.Recovery.PacketsRepaired > 0
			add(invariant, passed, fmt.Sprintf(
				"rtxSent=%d repaired=%d", result.Metrics.Recovery.RTXPacketsSent,
				result.Metrics.Recovery.PacketsRepaired,
			))
		case "keyframe-recovery":
			passed := result.Metrics.Recovery.StaleRTXRequestsSuppressed > 0 &&
				result.Metrics.Recovery.RecoveryKeyframeRequests > 0
			add(invariant, passed, fmt.Sprintf(
				"keyframeRequests=%d staleSuppressed=%d rtxSent=%d",
				result.Metrics.Recovery.RecoveryKeyframeRequests,
				result.Metrics.Recovery.StaleRTXRequestsSuppressed,
				result.Metrics.Recovery.RTXPacketsSent,
			))
		case "live-after-loss":
			lossObserved := recoveryMatrixObservedMediaLoss(result.Metrics)
			passed := result.Metrics.FramesResumedAfterRecovery > 0
			if !lossObserved {
				passed = result.Metrics.FramesSubmitted > 0 &&
					result.Metrics.FramesCompleted == result.Metrics.FramesSubmitted
			}
			add(invariant, passed, fmt.Sprintf(
				"lossObserved=%t submitted=%d completed=%d framesResumedAfterRecovery=%d",
				lossObserved, result.Metrics.FramesSubmitted, result.Metrics.FramesCompleted,
				result.Metrics.FramesResumedAfterRecovery,
			))
		case "ordered-once":
			passed := recoveryMatrixFrameIDsStrictlyIncrease(result.Metrics.CompletedFrameIDs) &&
				uint64(len(result.Metrics.CompletedFrameIDs)) == result.Metrics.FramesCompleted
			add(invariant, passed, fmt.Sprintf(
				"completed=%d observedIds=%d", result.Metrics.FramesCompleted,
				len(result.Metrics.CompletedFrameIDs),
			))
		case "bounded-state":
			passed := result.Metrics.Recovery.RetainedFramesCurrent == 0 &&
				result.Metrics.Recovery.RetainedFramesPeak <= defaultRecoveryFrameLimit &&
				result.Metrics.ResponderCache.PacketsCurrent == 0 &&
				result.Metrics.ResponderCache.PacketsPeak <= defaultRTXCachePackets &&
				result.Metrics.ResponderCache.BytesCurrent == 0 &&
				result.Metrics.ResponderCache.BytesPeak <= defaultRTXCacheBytes &&
				result.Metrics.Impairment.OutstandingMediaBytesCurrent == 0
			add(invariant, passed, fmt.Sprintf(
				"retainedFrames=%d/%d cachePackets=%d/%d cacheBytes=%d/%d outstandingMediaBytes=%d",
				result.Metrics.Recovery.RetainedFramesCurrent,
				result.Metrics.Recovery.RetainedFramesPeak,
				result.Metrics.ResponderCache.PacketsCurrent,
				result.Metrics.ResponderCache.PacketsPeak,
				result.Metrics.ResponderCache.BytesCurrent,
				result.Metrics.ResponderCache.BytesPeak,
				result.Metrics.Impairment.OutstandingMediaBytesCurrent,
			))
		case "clean-shutdown":
			add(invariant, result.Metrics.ShutdownComplete, fmt.Sprintf(
				"shutdownComplete=%t", result.Metrics.ShutdownComplete,
			))
		default:
			addInvalid(invariant, false, "unknown required invariant")
		}
	}

	switch {
	case invalid:
		result.Status = matrixStatusInvalid
		result.ActualOutcome = matrixStatusInvalid
	case fail:
		result.Status = matrixStatusFail
		result.ActualOutcome = "invariants-failed"
	default:
		result.Status = matrixStatusPass
		result.ActualOutcome = result.ExpectedOutcome
	}
	return result
}

func recoveryMatrixObservedMediaLoss(metrics recoveryMatrixMetrics) bool {
	if metrics.Recovery.NACKSequencesSent > 0 {
		return true
	}
	for _, class := range []recoveryPacketClass{matrixPacketOriginal, matrixPacketRTX} {
		if metrics.Impairment.ControllerDropped[class].Packets > 0 ||
			metrics.Impairment.EffectiveQueueDropped[class].Packets > 0 {
			return true
		}
	}
	return false
}

func matrixExecutionDetail(message string) string {
	if message == "" {
		return "no setup, watchdog, or asynchronous execution error"
	}
	return message
}

func recoveryMatrixCountersAreClean(snapshot RecoverySnapshot) bool {
	return snapshot.NACKPacketsSent == 0 && snapshot.NACKSequencesSent == 0 &&
		snapshot.NACKPacketsReceived == 0 && snapshot.NACKSequencesReceived == 0 &&
		snapshot.RTXPacketsSent == 0 && snapshot.RTXBytesSent == 0 &&
		snapshot.RTXPacketsReceived == 0 && snapshot.RTXBytesReceived == 0 &&
		snapshot.PacketsRepaired == 0 && snapshot.StaleRTXRequestsSuppressed == 0 &&
		snapshot.ResponderCacheMisses == 0 &&
		snapshot.RecoveryKeyframeRequests == 0 && snapshot.IncompleteFramesExpired == 0 &&
		snapshot.DependentFramesAbandoned == 0
}

func recoveryMatrixFrameIDsStrictlyIncrease(frameIDs []uint64) bool {
	for index := 1; index < len(frameIDs); index++ {
		if frameIDs[index] <= frameIDs[index-1] {
			return false
		}
	}
	return true
}

func recoveryMatrixAccountingReconciled(snapshot recoveryImpairmentSnapshot) (bool, string) {
	classes := []recoveryPacketClass{
		matrixPacketOriginal, matrixPacketRTX, matrixPacketNACK, matrixPacketOther,
	}
	for _, class := range classes {
		admitted := snapshot.AdmittedToVNet[class]
		delivered := snapshot.Delivered[class]
		if delivered.Packets > admitted.Packets || delivered.Bytes > admitted.Bytes {
			return false, fmt.Sprintf("%s delivered=%#v exceeds admitted=%#v", class, delivered, admitted)
		}
		expected := recoveryPacketTotals{
			Packets: admitted.Packets - delivered.Packets,
			Bytes:   admitted.Bytes - delivered.Bytes,
		}
		if actual, exists := snapshot.EffectiveQueueDropped[class]; exists && actual != expected {
			return false, fmt.Sprintf("%s effectiveQueueDropped=%#v want=%#v", class, actual, expected)
		}
	}
	return true, "admitted, delivered, and effective queue loss reconcile"
}

func writeRecoveryMatrixReport(path string, report recoveryMatrixReport) error {
	report.Results = append([]recoveryMatrixScenarioResult(nil), report.Results...)
	for index := range report.Results {
		report.Results[index].Metrics.CompletedFrameIDs = append(
			[]uint64{}, report.Results[index].Metrics.CompletedFrameIDs...,
		)
		report.Results[index].Metrics.KeyframeFrameIDs = append(
			[]uint64{}, report.Results[index].Metrics.KeyframeFrameIDs...,
		)
	}
	sort.Slice(report.Results, func(left, right int) bool {
		return report.Results[left].Name < report.Results[right].Name
	})
	encoded, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal recovery matrix report: %w", err)
	}
	encoded = append(encoded, '\n')
	temporaryPath := fmt.Sprintf("%s.tmp.%d", path, os.Getpid())
	file, err := os.OpenFile(temporaryPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return fmt.Errorf("create recovery matrix temporary report: %w", err)
	}
	keepTemporary := false
	defer func() {
		if !keepTemporary {
			_ = os.Remove(temporaryPath)
		}
	}()
	if _, err := file.Write(encoded); err != nil {
		_ = file.Close()
		return fmt.Errorf("write recovery matrix temporary report: %w", err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("close recovery matrix temporary report: %w", err)
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return fmt.Errorf("replace recovery matrix report: %w", err)
	}
	keepTemporary = true
	return nil
}

func TestRecoveryMatrixPercentileUsesNearestRankAndHandlesEmptyInput(t *testing.T) {
	samples := []time.Duration{
		time.Millisecond, 2 * time.Millisecond, 3 * time.Millisecond,
		4 * time.Millisecond, 100 * time.Millisecond,
	}
	got := summarizeRecoveryMatrixDurations(samples)
	if got.SampleCount != 5 || got.MinimumMilliseconds != 1 ||
		got.P50Milliseconds != 3 || got.P95Milliseconds != 100 ||
		got.P99Milliseconds != 100 || got.MaximumMilliseconds != 100 {
		t.Fatalf("summary = %#v", got)
	}
	if empty := summarizeRecoveryMatrixDurations(nil); empty != (recoveryMatrixLatencySummary{}) {
		t.Fatalf("empty summary = %#v", empty)
	}
}

func TestRecoveryMatrixOutcomeClassifiesFailuresAndInvalidRuns(t *testing.T) {
	base := recoveryMatrixScenarioResult{
		Name: "scenario", ExpectedOutcome: "bounded-recovery",
		Profile: recoveryMatrixProfile{RequiredInvariants: []string{
			"live-after-loss", "ordered-once", "bounded-state", "clean-shutdown",
		}},
		Metrics: recoveryMatrixMetrics{
			FramesSubmitted: 3, FramesCompleted: 3,
			FramesResumedAfterRecovery: 1, CompletedFrameIDs: []uint64{1, 2, 3},
			ShutdownComplete: true,
		},
	}
	cases := []struct {
		name       string
		mutate     func(*recoveryMatrixScenarioResult)
		wantStatus string
	}{
		{name: "pass", wantStatus: matrixStatusPass},
		{name: "no observed loss needs no recovery episode", wantStatus: matrixStatusPass, mutate: func(result *recoveryMatrixScenarioResult) {
			result.Metrics.FramesResumedAfterRecovery = 0
		}},
		{name: "no-loss zero delivery fails liveness", wantStatus: matrixStatusFail, mutate: func(result *recoveryMatrixScenarioResult) {
			result.Metrics.FramesSubmitted = 0
			result.Metrics.FramesCompleted = 0
			result.Metrics.FramesResumedAfterRecovery = 0
			result.Metrics.CompletedFrameIDs = nil
		}},
		{name: "no-loss partial delivery fails liveness", wantStatus: matrixStatusFail, mutate: func(result *recoveryMatrixScenarioResult) {
			result.Metrics.FramesCompleted = 2
			result.Metrics.FramesResumedAfterRecovery = 0
			result.Metrics.CompletedFrameIDs = []uint64{1, 2}
		}},
		{name: "observed NACK must resume", wantStatus: matrixStatusFail, mutate: func(result *recoveryMatrixScenarioResult) {
			result.Metrics.FramesResumedAfterRecovery = 0
			result.Metrics.Recovery.NACKSequencesSent = 1
		}},
		{name: "controller media loss must resume", wantStatus: matrixStatusFail, mutate: func(result *recoveryMatrixScenarioResult) {
			result.Metrics.FramesResumedAfterRecovery = 0
			result.Metrics.Impairment.ControllerDropped = map[recoveryPacketClass]recoveryPacketTotals{
				matrixPacketOriginal: {Packets: 1, Bytes: 1200},
			}
		}},
		{name: "clean NACK", wantStatus: matrixStatusFail, mutate: func(result *recoveryMatrixScenarioResult) {
			result.ExpectedOutcome = "clean"
			result.Profile.RequiredInvariants = []string{"clean", "ordered-once", "bounded-state", "clean-shutdown"}
			result.Metrics.Recovery.NACKPacketsSent = 1
		}},
		{name: "RTX repair absent", wantStatus: matrixStatusFail, mutate: func(result *recoveryMatrixScenarioResult) {
			result.ExpectedOutcome = "rtx-repair"
			result.Profile.RequiredInvariants = []string{"rtx-repair", "ordered-once", "bounded-state", "clean-shutdown"}
		}},
		{name: "stale recovery may include an earlier RTX improvement", wantStatus: matrixStatusPass, mutate: func(result *recoveryMatrixScenarioResult) {
			result.ExpectedOutcome = "keyframe-recovery"
			result.Profile.RequiredInvariants = []string{"keyframe-recovery", "ordered-once", "bounded-state", "clean-shutdown"}
			result.Metrics.Recovery.StaleRTXRequestsSuppressed = 1
			result.Metrics.Recovery.RTXPacketsSent = 1
			result.Metrics.Recovery.RecoveryKeyframeRequests = 1
		}},
		{name: "duplicate completed frame", wantStatus: matrixStatusFail, mutate: func(result *recoveryMatrixScenarioResult) {
			result.Metrics.CompletedFrameIDs = []uint64{1, 2, 2}
		}},
		{name: "non-increasing completed frame", wantStatus: matrixStatusFail, mutate: func(result *recoveryMatrixScenarioResult) {
			result.Metrics.CompletedFrameIDs = []uint64{1, 3, 2}
		}},
		{name: "retained assembly state", wantStatus: matrixStatusFail, mutate: func(result *recoveryMatrixScenarioResult) {
			result.Metrics.Recovery.RetainedFramesCurrent = 1
		}},
		{name: "retained responder state", wantStatus: matrixStatusFail, mutate: func(result *recoveryMatrixScenarioResult) {
			result.Metrics.ResponderCache.PacketsCurrent = 1
		}},
		{name: "assembler peak exceeds bound", wantStatus: matrixStatusFail, mutate: func(result *recoveryMatrixScenarioResult) {
			result.Metrics.Recovery.RetainedFramesPeak = defaultRecoveryFrameLimit + 1
		}},
		{name: "responder peak exceeds bound", wantStatus: matrixStatusFail, mutate: func(result *recoveryMatrixScenarioResult) {
			result.Metrics.ResponderCache.BytesPeak = defaultRTXCacheBytes + 1
		}},
		{name: "scheduled bytes", wantStatus: matrixStatusInvalid, mutate: func(result *recoveryMatrixScenarioResult) {
			result.Metrics.Impairment.ScheduledBytesCurrent = 1200
		}},
		{name: "unreconciled accounting", wantStatus: matrixStatusInvalid, mutate: func(result *recoveryMatrixScenarioResult) {
			result.Metrics.Impairment.AdmittedToVNet = map[recoveryPacketClass]recoveryPacketTotals{
				matrixPacketOriginal: {Packets: 1, Bytes: 1200},
			}
			result.Metrics.Impairment.Delivered = map[recoveryPacketClass]recoveryPacketTotals{
				matrixPacketOriginal: {Packets: 2, Bytes: 2400},
			}
		}},
		{name: "setup watchdog or async error", wantStatus: matrixStatusInvalid, mutate: func(result *recoveryMatrixScenarioResult) {
			result.Error = "watchdog expired"
		}},
		{name: "unknown invariant", wantStatus: matrixStatusInvalid, mutate: func(result *recoveryMatrixScenarioResult) {
			result.Profile.RequiredInvariants = append(result.Profile.RequiredInvariants, "unknown-rule")
		}},
		{name: "diagnostic latency outlier", wantStatus: matrixStatusPass, mutate: func(result *recoveryMatrixScenarioResult) {
			result.Metrics.SubmissionToAssembly = recoveryMatrixLatencySummary{
				SampleCount: 1, P99Milliseconds: 9_999, MaximumMilliseconds: 9_999,
			}
		}},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			result := cloneMatrixScenarioResult(base)
			if test.mutate != nil {
				test.mutate(&result)
			}
			got := evaluateRecoveryMatrixResult(result)
			if got.Status != test.wantStatus {
				t.Fatalf("status = %q, want %q; assertions = %#v", got.Status, test.wantStatus, got.Assertions)
			}
		})
	}
}

func TestRecoveryMatrixReportRoundTripsStrictlyAndWritesAtomically(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "matrix.json")
	report := recoveryMatrixReport{
		SchemaVersion: 1, CatalogSchemaVersion: 1,
		Parallelism:    4,
		SourceRevision: "abc123", SourceDirty: true, GoVersion: "go1.test",
		PionWebRTCVersion: "v4.2.15", PionTransportVersion: "v4.0.2",
		Tier:         matrixTierFast,
		StartedAtUTC: "2026-08-05T10:00:00Z", FinishedAtUTC: "2026-08-05T10:00:01Z",
		CatalogSHA256: "catalog-digest", HostDescription: "test host",
		Command: []string{"go", "test", "./..."},
		Results: []recoveryMatrixScenarioResult{
			{Name: "z-last", Seed: 8191, Status: matrixStatusPass, Assertions: []recoveryMatrixAssertion{{Name: "ordered-once", Passed: true, Detail: "strictly increasing"}}},
			{Name: "a-first", Seed: 1741, Status: matrixStatusFail, Assertions: []recoveryMatrixAssertion{{Name: "rtx-repair", Passed: false, Detail: "no repaired packet"}}, Metrics: recoveryMatrixMetrics{SubmissionToAssembly: recoveryMatrixLatencySummary{SampleCount: 1, P50Milliseconds: 2.5}}},
		},
	}
	if err := writeRecoveryMatrixReport(path, report); err != nil {
		t.Fatal(err)
	}
	encoded, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.HasSuffix(encoded, []byte{'\n'}) {
		t.Fatal("report has no trailing newline")
	}
	var shape struct {
		Results []struct {
			Metrics struct {
				CompletedFrameIDs json.RawMessage `json:"completedFrameIds"`
				KeyframeFrameIDs  json.RawMessage `json:"keyframeFrameIds"`
			} `json:"metrics"`
		} `json:"results"`
	}
	if err := json.Unmarshal(encoded, &shape); err != nil {
		t.Fatal(err)
	}
	for index, result := range shape.Results {
		if string(result.Metrics.CompletedFrameIDs) != "[]" ||
			string(result.Metrics.KeyframeFrameIDs) != "[]" {
			t.Fatalf(
				"result[%d] frame ID arrays = completed:%s keyframes:%s",
				index, result.Metrics.CompletedFrameIDs, result.Metrics.KeyframeFrameIDs,
			)
		}
	}
	decoder := json.NewDecoder(bytes.NewReader(encoded))
	decoder.DisallowUnknownFields()
	var decoded recoveryMatrixReport
	if err := decoder.Decode(&decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.SchemaVersion != 1 || decoded.CatalogSchemaVersion != 1 || decoded.Parallelism != 4 ||
		decoded.SourceRevision != "abc123" || !decoded.SourceDirty ||
		decoded.PionWebRTCVersion != "v4.2.15" || decoded.PionTransportVersion != "v4.0.2" {
		t.Fatalf("metadata = %#v", decoded)
	}
	if len(decoded.Results) != 2 || decoded.Results[0].Name != "a-first" ||
		decoded.Results[1].Name != "z-last" ||
		decoded.Results[0].Metrics.SubmissionToAssembly.P50Milliseconds != 2.5 ||
		decoded.Results[1].Assertions[0].Detail != "strictly increasing" {
		t.Fatalf("results = %#v", decoded.Results)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o644 {
		t.Fatalf("mode = %o", info.Mode().Perm())
	}
	temporary, err := filepath.Glob(path + ".tmp.*")
	if err != nil {
		t.Fatal(err)
	}
	if len(temporary) != 0 {
		t.Fatalf("temporary files remain: %v", temporary)
	}
}

func cloneMatrixScenarioResult(result recoveryMatrixScenarioResult) recoveryMatrixScenarioResult {
	cloned := result
	cloned.Profile = cloneRecoveryMatrixProfile(result.Profile)
	cloned.Metrics.CompletedFrameIDs = append([]uint64(nil), result.Metrics.CompletedFrameIDs...)
	return cloned
}
