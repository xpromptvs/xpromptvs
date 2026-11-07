package main

import (
	"bytes"
	"encoding/json"
	"slices"
	"testing"
)

func TestFlexFECProfileCatalogLoadsExactFamilies(t *testing.T) {
	catalog, err := loadFlexFECMatrixCatalog(nil)
	if err != nil {
		t.Fatal(err)
	}
	if catalog.SchemaVersion != 1 || len(catalog.Cases) != 28 {
		t.Fatalf("catalog schema/cases = %d/%d, want 1/28", catalog.SchemaVersion, len(catalog.Cases))
	}
	fast := resolvedFlexFECMatrixCases(catalog, matrixTierFast)
	extended := resolvedFlexFECMatrixCases(catalog, matrixTierExtended)
	if len(fast) != 7 || len(extended) != 28 {
		t.Fatalf("fast/extended counts = %d/%d, want 7/28", len(fast), len(extended))
	}
	wantFast := []string{
		"bandwidth-0p9x-q4", "burst-4", "clean", "jitter-10ms",
		"loss-1pct", "poor-wan", "twcc-loss-10pct",
	}
	gotFast := make([]string, len(fast))
	for index := range fast {
		gotFast[index] = fast[index].Name
		if fast[index].FPS != 60 || fast[index].MeasurementMode != "rtt-primed" ||
			fast[index].TotalRTPBudgetBitsPerSecond != 8_000_000 ||
			!slices.Equal(fast[index].ScalabilityModes, []string{"L1T1", "L1T3"}) {
			t.Fatalf("invalid fast case identity: %+v", fast[index])
		}
	}
	if !slices.Equal(gotFast, wantFast) {
		t.Fatalf("fast cases=%v, want %v", gotFast, wantFast)
	}
	poorWAN := fast[slices.IndexFunc(fast, func(value FlexFECMatrixCase) bool {
		return value.Name == "poor-wan"
	})]
	if poorWAN.Impairment.BandwidthPermille != 900 {
		t.Fatalf("poor-wan bandwidth = %d, want terminal-capable 900 permille",
			poorWAN.Impairment.BandwidthPermille)
	}
	bandwidth75Index := slices.IndexFunc(extended, func(value FlexFECMatrixCase) bool {
		return value.Name == "bandwidth-0p75x-q4"
	})
	if bandwidth75Index < 0 {
		t.Fatal("missing bandwidth-0p75x-q4")
	}
	bandwidth75 := extended[bandwidth75Index]
	if bandwidth75.Impairment.BandwidthPermille != 750 ||
		bandwidth75.Impairment.BandwidthDurationMilliseconds != 1_500 ||
		bandwidth75.Impairment.QueueFrames != 4 {
		t.Fatalf("finite 75%% bandwidth episode = %#v", bandwidth75.Impairment)
	}
	for _, family := range []string{
		"loss-0p1pct", "loss-0p5pct", "loss-1pct", "loss-2pct", "loss-5pct",
		"burst-1", "burst-2", "burst-4", "burst-8",
		"jitter-1ms", "jitter-5ms", "jitter-10ms", "jitter-20ms",
		"rtt-10ms", "rtt-50ms", "rtt-100ms",
		"twcc-loss-5pct", "twcc-loss-10pct", "nack-loss-10pct",
		"rtx-loss-10pct", "fec-loss-10pct", "bandwidth-0p9x-q4",
		"bandwidth-0p75x-q4", "good-wifi", "congested-wifi",
		"moderate-wan", "poor-wan", "clean",
	} {
		if !slices.ContainsFunc(extended, func(value FlexFECMatrixCase) bool {
			return value.Name == family
		}) {
			t.Fatalf("missing family %q", family)
		}
	}
}

func TestFlexFECBandwidthProfilesUseFiniteEpisodes(t *testing.T) {
	catalog, err := loadFlexFECMatrixCatalog(nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"bandwidth-0p9x-q4", "bandwidth-0p75x-q4"} {
		index := slices.IndexFunc(catalog.Cases, func(value FlexFECMatrixCase) bool {
			return value.Name == name
		})
		if index < 0 {
			t.Fatalf("missing %s", name)
		}
		profile := catalog.Cases[index].Impairment
		if profile.BandwidthDurationMilliseconds != 1_500 {
			t.Fatalf("%s bandwidth duration = %d ms, want 1500 ms",
				name, profile.BandwidthDurationMilliseconds)
		}
	}
}

func TestFlexFECProfileCatalogIsStrictAndImmutable(t *testing.T) {
	catalog, err := loadFlexFECMatrixCatalog(nil)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(catalog)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := loadFlexFECMatrixCatalog(append(encoded, []byte(` {}`)...)); err == nil {
		t.Fatal("accepted trailing JSON")
	}
	withUnknown := bytes.Replace(encoded, []byte(`"schemaVersion":1`),
		[]byte(`"schemaVersion":1,"unknown":true`), 1)
	if _, err := loadFlexFECMatrixCatalog(withUnknown); err == nil {
		t.Fatal("accepted unknown field")
	}

	firstName := catalog.Cases[0].Name
	catalog.Cases[0].Name = "mutated"
	fresh, err := loadFlexFECMatrixCatalog(nil)
	if err != nil {
		t.Fatal(err)
	}
	if fresh.Cases[0].Name != firstName {
		t.Fatal("embedded catalog was mutable")
	}
}

func TestFlexFECProfileCatalogRejectsInvalidIdentity(t *testing.T) {
	valid, err := loadFlexFECMatrixCatalog(nil)
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name   string
		mutate func(*FlexFECMatrixCatalog)
	}{
		{name: "duplicate", mutate: func(value *FlexFECMatrixCatalog) {
			value.Cases[1].Name = value.Cases[0].Name
		}},
		{name: "fps", mutate: func(value *FlexFECMatrixCatalog) { value.Cases[0].FPS = 30 }},
		{name: "mode", mutate: func(value *FlexFECMatrixCatalog) { value.Cases[0].MeasurementMode = "cold-start" }},
		{name: "budget", mutate: func(value *FlexFECMatrixCatalog) { value.Cases[0].TotalRTPBudgetBitsPerSecond = 7_000_000 }},
		{name: "scalability", mutate: func(value *FlexFECMatrixCatalog) {
			value.Cases[0].ScalabilityModes = []string{"L1T1"}
		}},
		{name: "missing seeds", mutate: func(value *FlexFECMatrixCatalog) {
			for index := range value.Cases {
				if value.Cases[index].Name == "loss-1pct" {
					value.Cases[index].Seeds = nil
				}
			}
		}},
		{name: "profile schema", mutate: func(value *FlexFECMatrixCatalog) { value.Cases[0].Impairment.SchemaVersion = 1 }},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			candidate := cloneFlexFECMatrixCatalog(valid)
			test.mutate(&candidate)
			encoded, err := json.Marshal(candidate)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := loadFlexFECMatrixCatalog(encoded); err == nil {
				t.Fatal("accepted invalid catalog")
			}
		})
	}
}
