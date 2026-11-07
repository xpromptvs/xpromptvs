package main

import (
	"bytes"
	"encoding/json"
	"os"
	"slices"
	"testing"
)

func TestDefaultFlexFECControllerPolicyMatchesSelectedWANPolicy(t *testing.T) {
	data, err := os.ReadFile("testdata/selected_wan_flexfec_policy.json")
	if err != nil {
		t.Fatal(err)
	}
	var artifact struct {
		Evidence struct {
			ControllerPolicySHA256 map[string]string `json:"controllerPolicySHA256"`
		} `json:"evidence"`
		Selected struct {
			ID         string                  `json:"id"`
			Policy     string                  `json:"policy"`
			Controller FlexFECControllerPolicy `json:"controller"`
		} `json:"selected"`
	}
	if err := json.Unmarshal(data, &artifact); err != nil {
		t.Fatal(err)
	}
	assets, err := loadFlexFECControllerAssets(nil)
	if err != nil {
		t.Fatal(err)
	}
	wantSHA := artifact.Evidence.ControllerPolicySHA256[artifact.Selected.ID]
	if artifact.Selected.Policy != "adaptive" ||
		artifact.Selected.ID != artifact.Selected.Controller.ControllerVersion ||
		assets.Policy != artifact.Selected.Controller ||
		assets.PolicySHA256 != wantSHA {
		t.Fatalf("embedded=%#v sha=%s selected=%#v sha=%s",
			assets.Policy, assets.PolicySHA256, artifact.Selected, wantSHA)
	}
}

func TestFlexFECControllerPolicyLoadsEmbeddedAssets(t *testing.T) {
	assets, err := loadFlexFECControllerAssets(nil)
	if err != nil {
		t.Fatal(err)
	}
	wantTiers := []FlexFECTier{
		FlexFECTierOff, FlexFECTierLow, FlexFECTierMedium, FlexFECTierHigh,
	}
	if !slices.Equal(assets.AllowedTiers, wantTiers) {
		t.Fatalf("allowed tiers = %v, want %v", assets.AllowedTiers, wantTiers)
	}
	policy := assets.Policy
	if policy.ControllerVersion != "ll100-d1000-h250-b2x4" ||
		policy.EvaluationIntervalMilliseconds != 100 ||
		policy.MinimumFinalizedPackets != 64 ||
		policy.ReorderingGraceMilliseconds != 25 ||
		policy.UpHoldWindows != 2 ||
		policy.DownCleanMilliseconds != 1_000 ||
		policy.TransitionHoldMilliseconds != 250 ||
		policy.FeedbackStaleMilliseconds != 750 ||
		policy.LowLossBasisPoints != 100 ||
		policy.MediumLossBasisPoints != 100 ||
		policy.HighLossBasisPoints != 300 ||
		policy.RepairLossMinimumPackets != 8 ||
		policy.RepairLossCapBasisPoints != 5_000 ||
		policy.BurstWindowMilliseconds != 50 ||
		policy.MediumBurstPackets != 2 || policy.HighBurstPackets != 4 ||
		policy.QueueTrendMilliseconds != 3 {
		t.Fatalf("embedded policy = %#v", policy)
	}
	for label, digest := range map[string]string{
		"policy": assets.PolicySHA256, "retained tiers": assets.RetainedTiersSHA256,
	} {
		if len(digest) != 64 {
			t.Fatalf("%s SHA-256 = %q", label, digest)
		}
	}
}

func TestFlexFECControllerPolicyStrictlyParsesExplicitCandidate(t *testing.T) {
	assets, err := loadFlexFECControllerAssets(nil)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(assets.Policy)
	if err != nil {
		t.Fatal(err)
	}
	explicit, err := loadFlexFECControllerAssets(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if explicit.Policy != assets.Policy || explicit.PolicySHA256 == assets.PolicySHA256 {
		t.Fatalf("explicit assets = %#v, embedded = %#v", explicit, assets)
	}
	if _, err := loadFlexFECControllerAssets(append(encoded, []byte(` {}`)...)); err == nil {
		t.Fatal("accepted trailing JSON")
	}
	unknown := bytes.Replace(encoded, []byte(`"schemaVersion":1`),
		[]byte(`"schemaVersion":1,"unknown":true`), 1)
	if _, err := loadFlexFECControllerAssets(unknown); err == nil {
		t.Fatal("accepted unknown policy field")
	}
}

func TestFlexFECControllerPolicyRejectsInvalidValues(t *testing.T) {
	assets, err := loadFlexFECControllerAssets(nil)
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name   string
		mutate func(*FlexFECControllerPolicy)
	}{
		{name: "schema", mutate: func(value *FlexFECControllerPolicy) { value.SchemaVersion = 2 }},
		{name: "version", mutate: func(value *FlexFECControllerPolicy) { value.ControllerVersion = "" }},
		{name: "evaluation", mutate: func(value *FlexFECControllerPolicy) { value.EvaluationIntervalMilliseconds = 0 }},
		{name: "minimum packets", mutate: func(value *FlexFECControllerPolicy) { value.MinimumFinalizedPackets = 0 }},
		{name: "reordering", mutate: func(value *FlexFECControllerPolicy) { value.ReorderingGraceMilliseconds = 0 }},
		{name: "up hold", mutate: func(value *FlexFECControllerPolicy) { value.UpHoldWindows = 0 }},
		{name: "down clean", mutate: func(value *FlexFECControllerPolicy) { value.DownCleanMilliseconds = 50 }},
		{name: "transition hold", mutate: func(value *FlexFECControllerPolicy) { value.TransitionHoldMilliseconds = 50 }},
		{name: "feedback stale", mutate: func(value *FlexFECControllerPolicy) { value.FeedbackStaleMilliseconds = 50 }},
		{name: "loss order", mutate: func(value *FlexFECControllerPolicy) { value.LowLossBasisPoints = value.MediumLossBasisPoints + 1 }},
		{name: "high loss", mutate: func(value *FlexFECControllerPolicy) { value.HighLossBasisPoints = 10_001 }},
		{name: "repair packets", mutate: func(value *FlexFECControllerPolicy) { value.RepairLossMinimumPackets = 0 }},
		{name: "repair loss", mutate: func(value *FlexFECControllerPolicy) { value.RepairLossCapBasisPoints = 10_001 }},
		{name: "burst window", mutate: func(value *FlexFECControllerPolicy) { value.BurstWindowMilliseconds = 0 }},
		{name: "burst order", mutate: func(value *FlexFECControllerPolicy) { value.HighBurstPackets = value.MediumBurstPackets }},
		{name: "queue trend", mutate: func(value *FlexFECControllerPolicy) { value.QueueTrendMilliseconds = 0 }},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			candidate := assets.Policy
			test.mutate(&candidate)
			encoded, err := json.Marshal(candidate)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := loadFlexFECControllerAssets(encoded); err == nil {
				t.Fatalf("accepted invalid policy: %s", encoded)
			}
		})
	}
}

func TestFlexFECControllerPolicyAllowsCollapsedLowAndMediumThreshold(t *testing.T) {
	assets, err := loadFlexFECControllerAssets(nil)
	if err != nil {
		t.Fatal(err)
	}
	candidate := assets.Policy
	candidate.LowLossBasisPoints = candidate.MediumLossBasisPoints
	encoded, err := json.Marshal(candidate)
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := loadFlexFECControllerAssets(encoded)
	if err != nil {
		t.Fatal(err)
	}
	controller := &FlexFECController{policy: parsed.Policy}
	if tier := controller.lossTierLocked(candidate.MediumLossBasisPoints); tier != FlexFECTierMedium {
		t.Fatalf("equal low/medium threshold tier = %v, want medium", tier)
	}
}

func TestFlexFECControllerRetainedTiersAreStrictAndPrependOff(t *testing.T) {
	valid := `{"schemaVersion":1,"evidenceKind":"flexfec-retained-static-tiers","binarySHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","sourceRevision":"revision","sourceRevisionSHA256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","tiers":["low","high"]}`
	tiers, _, err := parseRetainedFlexFECTiers([]byte(valid))
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(tiers, []FlexFECTier{FlexFECTierOff, FlexFECTierLow, FlexFECTierHigh}) {
		t.Fatalf("tiers = %v", tiers)
	}
	for _, invalid := range []string{
		`{"schemaVersion":1,"evidenceKind":"flexfec-retained-static-tiers","binarySHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","sourceRevision":"revision","sourceRevisionSHA256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","tiers":[]}`,
		`{"schemaVersion":1,"evidenceKind":"flexfec-retained-static-tiers","binarySHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","sourceRevision":"revision","sourceRevisionSHA256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","tiers":["medium","low"]}`,
		`{"schemaVersion":1,"evidenceKind":"flexfec-retained-static-tiers","binarySHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","sourceRevision":"revision","sourceRevisionSHA256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","tiers":["low","low"]}`,
		`{"schemaVersion":1,"evidenceKind":"flexfec-retained-static-tiers","binarySHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","sourceRevision":"revision","sourceRevisionSHA256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","tiers":["off","low"]}`,
	} {
		if _, _, err := parseRetainedFlexFECTiers([]byte(invalid)); err == nil {
			t.Fatalf("accepted invalid retained tiers: %s", invalid)
		}
	}
}
