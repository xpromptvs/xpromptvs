package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"
)

func TestWANFlexFECCandidateCatalogMatchesRuntimePolicy(t *testing.T) {
	type control struct {
		ID     string `json:"id"`
		Policy string `json:"policy"`
	}
	type candidate struct {
		ID      string          `json:"id"`
		Policy  json.RawMessage `json:"policy"`
		Control bool            `json:"control"`
	}
	var catalog struct {
		SchemaVersion           int         `json:"schemaVersion"`
		EvidenceKind            string      `json:"evidenceKind"`
		SelectedRTXPolicySHA256 string      `json:"selectedRTXPolicySHA256"`
		Controls                []control   `json:"controls"`
		Candidates              []candidate `json:"candidates"`
	}
	encoded, err := os.ReadFile("testdata/wan_flexfec_candidates.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(encoded, &catalog); err != nil {
		t.Fatal(err)
	}
	selected, err := os.ReadFile("testdata/selected_wan_rtx_age_policy.json")
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(selected)
	if catalog.SchemaVersion != 1 ||
		catalog.EvidenceKind != "wan-flexfec-controller-candidates" ||
		catalog.SelectedRTXPolicySHA256 != hex.EncodeToString(digest[:]) {
		t.Fatalf("catalog identity = %#v", catalog)
	}
	wantControls := []control{
		{ID: "off", Policy: "off"},
		{ID: "low", Policy: "low"},
		{ID: "medium", Policy: "medium"},
		{ID: "high", Policy: "high"},
	}
	if len(catalog.Controls) != len(wantControls) {
		t.Fatalf("controls = %#v", catalog.Controls)
	}
	for index := range wantControls {
		if catalog.Controls[index] != wantControls[index] {
			t.Fatalf("controls[%d] = %#v", index, catalog.Controls[index])
		}
	}
	if len(catalog.Candidates) != 36 {
		t.Fatalf("candidate count = %d, want 36", len(catalog.Candidates))
	}
	index := 0
	for _, low := range []int{25, 50, 100} {
		for _, decay := range []int{1000, 1500, 2500} {
			for _, hold := range []int{250, 500} {
				for _, burst := range [][2]int{{2, 4}, {3, 6}} {
					item := catalog.Candidates[index]
					assets, err := loadFlexFECControllerAssets(item.Policy)
					if err != nil {
						t.Fatalf("candidate %s: %v", item.ID, err)
					}
					policy := assets.Policy
					if policy.ControllerVersion != item.ID ||
						policy.LowLossBasisPoints != low ||
						policy.DownCleanMilliseconds != decay ||
						policy.TransitionHoldMilliseconds != hold ||
						policy.MediumBurstPackets != burst[0] ||
						policy.HighBurstPackets != burst[1] {
						t.Fatalf("candidate[%d] = %#v", index, policy)
					}
					wantControl := item.ID == "ll050-d1500-h250-b2x4"
					if item.Control != wantControl {
						t.Fatalf("candidate %s control = %t", item.ID, item.Control)
					}
					index++
				}
			}
		}
	}
}
