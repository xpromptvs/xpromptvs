package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"testing"
)

func TestWANRecoveryCatalogIsFrozenAndComplete(t *testing.T) {
	catalog, err := loadWANRecoveryCatalog(wanRecoveryCatalogJSON)
	if err != nil {
		t.Fatal(err)
	}
	if catalog.SchemaVersion != 1 || len(catalog.Profiles) != 28 {
		t.Fatalf("WAN catalog identity/count = %d/%d", catalog.SchemaVersion, len(catalog.Profiles))
	}
	wantSeeds := []int64{1_741, 8_191, 65_537}
	wantModes := []string{"L1T1", "L1T3"}
	familyCounts := map[string]int{}
	seen := map[string]bool{}
	for _, profile := range catalog.Profiles {
		if seen[profile.ID] {
			t.Fatalf("duplicate WAN profile ID %q", profile.ID)
		}
		seen[profile.ID] = true
		familyCounts[profile.Family]++
		if profile.FPS != 60 || profile.MeasurementMode != "rtt-primed" ||
			profile.RTTPrimingMilliseconds != 1_000 ||
			profile.TotalRTPBudgetBitsPerSecond != 8_000_000 ||
			!slices.Equal(profile.ScalabilityModes, wantModes) ||
			profile.Impairment.SchemaVersion != 3 || profile.Impairment.rtxMaxAgePresent ||
			profile.Impairment.RTXMaxAgeMilliseconds != 0 ||
			profile.Impairment.FPS != 60 ||
			profile.Impairment.NominalMediaBitsPerSecond != 8_000_000 {
			t.Fatalf("invalid frozen WAN profile %q: %#v", profile.ID, profile)
		}
		if profile.Impairment.isProbabilistic() {
			if !slices.Equal(profile.Seeds, wantSeeds) {
				t.Fatalf("probabilistic seeds for %q = %v", profile.ID, profile.Seeds)
			}
		} else if len(profile.Seeds) != 0 {
			t.Fatalf("deterministic profile %q has seeds %v", profile.ID, profile.Seeds)
		}
	}
	if want := map[string]int{
		"rtt-jitter": 18, "loss": 3, "burst": 3,
		"nack-loss": 1, "rtx-loss": 1, "bandwidth": 2,
	}; !mapsEqual(familyCounts, want) {
		t.Fatalf("WAN family counts = %v, want %v", familyCounts, want)
	}

	for _, rtt := range []int{10, 50, 100, 200, 300, 500} {
		for _, jitter := range []int{0, 10, 30} {
			profile := mustWANProfile(t, catalog, fmt.Sprintf("rtt-%03d-jitter-%02d-loss-1pct", rtt, jitter))
			if profile.Impairment.OneWayDelayMicroseconds != rtt*500 ||
				profile.Impairment.MaxJitterMicroseconds != jitter*1_000 ||
				profile.Impairment.MediaLossBasisPoints != 100 {
				t.Fatalf("RTT/jitter profile mismatch: %#v", profile)
			}
		}
	}
	for loss, basisPoints := range map[string]int{"0p5": 50, "1": 100, "2": 200} {
		profile := mustWANProfile(t, catalog, "loss-"+loss+"pct")
		if profile.Impairment.MediaLossBasisPoints != basisPoints {
			t.Fatalf("loss profile mismatch: %#v", profile)
		}
	}
	for _, length := range []int{1, 4, 8} {
		profile := mustWANProfile(t, catalog, fmt.Sprintf("burst-%d", length))
		coordinates := profile.Impairment.Bursts[0].SourceCoordinates
		if len(coordinates) != length {
			t.Fatalf("burst-%d coordinates = %v", length, coordinates)
		}
		for index, coordinate := range coordinates {
			if coordinate.FrameOrdinal != 30 || coordinate.PacketIndex != uint64(index+1) {
				t.Fatalf("burst-%d coordinate %d = %#v", length, index, coordinate)
			}
		}
	}
	if mustWANProfile(t, catalog, "nack-loss-10pct").Impairment.NACKLossBasisPoints != 1_000 ||
		mustWANProfile(t, catalog, "rtx-loss-10pct").Impairment.RTXLossBasisPoints != 1_000 {
		t.Fatal("10% recovery-packet loss families are incomplete")
	}
	for _, permille := range []int{900, 750} {
		profile := mustWANProfile(t, catalog, fmt.Sprintf("bandwidth-%03d-q4", permille))
		if profile.Impairment.BandwidthPermille != permille ||
			profile.Impairment.BandwidthDurationMilliseconds != 1_500 ||
			profile.Impairment.QueueFrames != 4 {
			t.Fatalf("bandwidth profile mismatch: %#v", profile)
		}
	}
	wantSHA256 := "22e93bdab68798f171292020cfca776408b8518146a636a731cbf1b206acff48"
	if got := fmt.Sprintf("%x", sha256.Sum256(wanRecoveryCatalogJSON)); got != wantSHA256 {
		t.Fatalf("WAN catalog sha256 = %s, want %s", got, wantSHA256)
	}
}

func TestWANRecoveryCatalogRTXAgeCandidatesAreFrozenInExactOrder(t *testing.T) {
	catalog, err := loadWANRTXAgeCandidates(wanRTXAgeCandidatesJSON)
	if err != nil {
		t.Fatal(err)
	}
	wantIDs := []string{
		"fixed-030", "fixed-075", "fixed-150", "fixed-300", "fixed-500",
		"rtt-m1000-c300", "rtt-m1000-c500", "rtt-m1250-c300",
		"rtt-m1250-c500", "rtt-m1500-c300", "rtt-m1500-c500",
	}
	gotIDs := make([]string, len(catalog.Candidates))
	for index, candidate := range catalog.Candidates {
		gotIDs[index] = candidate.ID
		if index < 5 {
			wantAge := []int{30, 75, 150, 300, 500}[index]
			if candidate.Mode != "fixed" || candidate.RTXMaxAgeMilliseconds != wantAge ||
				candidate.MultiplierMilli != 1_000 || candidate.CapMilliseconds != wantAge {
				t.Fatalf("fixed candidate %d = %#v", index, candidate)
			}
		} else if candidate.Mode != "rtt" || candidate.RTXMaxAgeMilliseconds != 30 ||
			!slices.Contains([]int{1_000, 1_250, 1_500}, candidate.MultiplierMilli) ||
			!slices.Contains([]int{300, 500}, candidate.CapMilliseconds) {
			t.Fatalf("RTT candidate %d = %#v", index, candidate)
		}
	}
	if !slices.Equal(gotIDs, wantIDs) {
		t.Fatalf("RTX candidate IDs = %v, want %v", gotIDs, wantIDs)
	}
	wantSHA256 := "b3b13405734271aea9e6e6402a76449f83f94481eef90cb660ea4e1f1b0205c9"
	if got := fmt.Sprintf("%x", sha256.Sum256(wanRTXAgeCandidatesJSON)); got != wantSHA256 {
		t.Fatalf("RTX candidate sha256 = %s, want %s", got, wantSHA256)
	}
}

func TestRecoveryMatrixCatalogLoadsAndResolvesStableOrder(t *testing.T) {
	catalog, err := loadRecoveryMatrixCatalog(recoveryMatrixCatalogJSON)
	if err != nil {
		t.Fatal(err)
	}
	fast, err := resolvedRecoveryMatrixProfiles(catalog, matrixTierFast, "", nil)
	if err != nil {
		t.Fatal(err)
	}
	wantNames := []string{
		"clean",
		"duplication-reordering",
		"first-nack-loss",
		"first-rtx-loss",
		"four-packet-burst",
		"loss-jitter",
		"poor-wifi-short",
		"random-loss-1pct",
		"single-original-loss",
		"stale-loss-keyframe",
	}
	gotNames := make([]string, len(fast))
	for index := range fast {
		gotNames[index] = fast[index].Name
	}
	if !slices.Equal(gotNames, wantNames) {
		t.Fatalf("fast profile names = %v, want %v", gotNames, wantNames)
	}
	if len(catalog.Profiles) <= len(fast) {
		t.Fatalf("catalog has no extended profiles: %d total", len(catalog.Profiles))
	}
}

func TestRecoveryMatrixCatalogRejectsMalformedProfiles(t *testing.T) {
	valid := `{"schemaVersion":1,"profiles":[]}`
	cases := []struct {
		name string
		json string
	}{
		{name: "unknown field", json: `{"schemaVersion":1,"unknown":true,"profiles":[]}`},
		{name: "wrong schema", json: `{"schemaVersion":2,"profiles":[]}`},
		{name: "trailing object", json: valid + valid},
		{name: "duplicate name", json: matrixCatalogWithProfiles(
			matrixMinimalProfileJSON("duplicate"), matrixMinimalProfileJSON("duplicate"),
		)},
		{name: "zero fps", json: matrixCatalogWithProfiles(
			matrixMinimalProfileWithJSON("zero-fps", `"fps":0`),
		)},
		{name: "probabilistic without seed", json: matrixCatalogWithProfiles(
			matrixMinimalProfileWithJSON("missing-seed", `"seed":null,"mediaLossBasisPoints":10`),
		)},
		{name: "jitter and duplication", json: matrixCatalogWithProfiles(
			matrixMinimalProfileWithJSON(
				"conflicting-delay", `"maxJitterMicroseconds":1000,"immediateDuplicationBasisPoints":10`,
			),
		)},
		{name: "bandwidth without queue", json: matrixCatalogWithProfiles(
			matrixMinimalProfileWithJSON("missing-queue", `"bandwidthPermille":1000,"queueFrames":0`),
		)},
		{name: "bandwidth duration without bandwidth", json: matrixCatalogWithProfiles(
			matrixMinimalProfileWithJSON("orphaned-bandwidth-duration", `"bandwidthDurationMilliseconds":100`),
		)},
		{name: "negative bandwidth duration", json: matrixCatalogWithProfiles(
			matrixMinimalProfileWithJSON("negative-bandwidth-duration", `"bandwidthPermille":750,"queueFrames":4,"bandwidthDurationMilliseconds":-1`),
		)},
		{name: "mixed source and ordinal selector", json: matrixCatalogWithProfiles(
			matrixMinimalProfileWithJSON("mixed-selector", `"bursts":[{"selectorType":"source-coordinates","startOriginalOrdinal":1,"length":1,"sourceCoordinates":[{"frameOrdinal":2,"packetIndex":1}]}]`),
		)},
		{name: "duplicate source coordinate", json: matrixCatalogWithProfiles(
			matrixMinimalProfileWithJSON("duplicate-coordinate", `"bursts":[{"selectorType":"source-coordinates","sourceCoordinates":[{"frameOrdinal":2,"packetIndex":1},{"frameOrdinal":2,"packetIndex":1}]}]`),
		)},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			if _, err := loadRecoveryMatrixCatalog([]byte(test.json)); err == nil {
				t.Fatalf("accepted invalid catalog: %s", test.json)
			}
		})
	}
}

func TestRecoveryMatrixProfileAcceptsFiniteBandwidthEpisode(t *testing.T) {
	profile, err := parseRecoveryMatrixProfile([]byte(matrixMinimalProfileWithJSON(
		"finite-bandwidth", `"bandwidthPermille":750,"queueFrames":4,"bandwidthDurationMilliseconds":1500`,
	)))
	if err != nil {
		t.Fatal(err)
	}
	if profile.BandwidthPermille != 750 || profile.QueueFrames != 4 ||
		profile.BandwidthDurationMilliseconds != 1_500 {
		t.Fatalf("finite bandwidth profile = %#v", profile)
	}
}

func TestRecoveryMatrixProfileSchema3DecouplesRTXPolicy(t *testing.T) {
	schema3 := matrixMinimalProfileMap("schema-3")
	schema3["schemaVersion"] = 3
	delete(schema3, "rtxMaxAgeMilliseconds")
	schema3["oneWayDelayMicroseconds"] = 50_000
	schema3["maxJitterMicroseconds"] = 10_000
	schema3["mediaLossBasisPoints"] = 100
	schema3["nackLossBasisPoints"] = 1_000
	schema3["rtxLossBasisPoints"] = 1_000
	schema3["bandwidthPermille"] = 750
	schema3["bandwidthDurationMilliseconds"] = 1_500
	schema3["queueFrames"] = 4
	schema3["bursts"] = []any{map[string]any{
		"selectorType": "source-coordinates",
		"sourceCoordinates": []any{
			map[string]any{"frameOrdinal": 30, "packetIndex": 1},
		},
	}}
	parsed, err := parseRecoveryMatrixProfile(mustJSON(t, schema3))
	if err != nil {
		t.Fatal(err)
	}
	if parsed.SchemaVersion != 3 || parsed.RTXMaxAgeMilliseconds != 0 ||
		parsed.OneWayDelayMicroseconds != 50_000 || parsed.MaxJitterMicroseconds != 10_000 ||
		parsed.MediaLossBasisPoints != 100 || parsed.NACKLossBasisPoints != 1_000 ||
		parsed.RTXLossBasisPoints != 1_000 || parsed.BandwidthPermille != 750 ||
		parsed.BandwidthDurationMilliseconds != 1_500 || parsed.QueueFrames != 4 ||
		len(parsed.Bursts) != 1 {
		t.Fatalf("schema-3 profile lost deterministic fields: %#v", parsed)
	}

	withAge := mapsClone(schema3)
	withAge["rtxMaxAgeMilliseconds"] = 30
	if _, err := parseRecoveryMatrixProfile(mustJSON(t, withAge)); err == nil {
		t.Fatal("schema 3 accepted embedded RTX policy")
	}
	unknown := mapsClone(schema3)
	unknown["unknown"] = true
	if _, err := parseRecoveryMatrixProfile(mustJSON(t, unknown)); err == nil {
		t.Fatal("schema 3 accepted an unknown field")
	}

	schema2 := matrixMinimalProfileMap("schema-2")
	schema2["schemaVersion"] = 2
	if _, err := parseRecoveryMatrixProfile(mustJSON(t, schema2)); err != nil {
		t.Fatalf("schema 2 compatibility failed: %v", err)
	}
	delete(schema2, "rtxMaxAgeMilliseconds")
	if _, err := parseRecoveryMatrixProfile(mustJSON(t, schema2)); err == nil {
		t.Fatal("schema 2 accepted a missing embedded RTX age")
	}
}

func TestRecoveryMatrixProfileReadsLegacyAndSourceCoordinateSelectors(t *testing.T) {
	legacy, err := parseRecoveryMatrixProfile([]byte(matrixMinimalProfileWithJSON(
		"legacy", `"bursts":[{"startOriginalOrdinal":7,"length":3}]`,
	)))
	if err != nil {
		t.Fatal(err)
	}
	if len(legacy.Bursts) != 1 || legacy.Bursts[0].SelectorType != "" {
		t.Fatalf("legacy burst = %#v", legacy.Bursts)
	}

	source, err := parseRecoveryMatrixProfile([]byte(matrixMinimalProfileWithJSON(
		"source", `"bursts":[{"selectorType":"source-coordinates","sourceCoordinates":[{"frameOrdinal":2,"packetIndex":1},{"frameOrdinal":5,"packetIndex":1}]}]`,
	)))
	if err != nil {
		t.Fatal(err)
	}
	if got := source.Bursts[0].SourceCoordinates; len(got) != 2 ||
		got[0].FrameOrdinal != 2 || got[1].PacketIndex != 1 {
		t.Fatalf("source coordinates = %#v", got)
	}
}

func TestRecoveryMatrixProfileAcceptsIndependentFECAndTWCCLoss(t *testing.T) {
	profile, err := parseRecoveryMatrixProfile([]byte(matrixMinimalProfileWithJSON(
		"fec-twcc", `"fecLossBasisPoints":1000,"twccLossBasisPoints":2000,"dropFirstFec":true,"dropFirstTwcc":true`,
	)))
	if err != nil {
		t.Fatal(err)
	}
	if profile.FECLossBasisPoints != 1000 || profile.TWCCLossBasisPoints != 2000 ||
		!profile.DropFirstFEC || !profile.DropFirstTWCC {
		t.Fatalf("independent loss fields = %#v", profile)
	}
	for _, field := range []string{"fecLossBasisPoints", "twccLossBasisPoints"} {
		invalid := matrixMinimalProfileWithJSON("invalid-"+field, fmt.Sprintf(`%q:10001`, field))
		if _, err := parseRecoveryMatrixProfile([]byte(invalid)); err == nil {
			t.Fatalf("accepted out-of-range %s", field)
		}
	}
}

func TestRecoveryMatrixCatalogSelectsExactProfileAndOverridesProbabilisticSeed(t *testing.T) {
	catalog, err := loadRecoveryMatrixCatalog(recoveryMatrixCatalogJSON)
	if err != nil {
		t.Fatal(err)
	}
	seed := int64(9_999)
	selected, err := resolvedRecoveryMatrixProfiles(
		catalog, matrixTierExtended, "random-loss-1pct", &seed,
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(selected) != 1 || selected[0].Name != "random-loss-1pct" ||
		selected[0].Seed == nil || *selected[0].Seed != seed {
		t.Fatalf("selected profiles = %#v", selected)
	}
	if _, err := resolvedRecoveryMatrixProfiles(
		catalog, matrixTierExtended, "clean", &seed,
	); err == nil {
		t.Fatal("accepted seed override for deterministic profile")
	}
	if _, err := resolvedRecoveryMatrixProfiles(
		catalog, matrixTierFast, "does-not-exist", nil,
	); err == nil {
		t.Fatal("accepted unknown profile")
	}
}

func TestRecoveryMatrixCatalogContainsCompleteExtendedSweeps(t *testing.T) {
	catalog, err := loadRecoveryMatrixCatalog(recoveryMatrixCatalogJSON)
	if err != nil {
		t.Fatal(err)
	}
	extended, err := resolvedRecoveryMatrixProfiles(catalog, matrixTierExtended, "", nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(extended) != 91 {
		t.Fatalf("extended profile count = %d, want 91", len(extended))
	}
	for _, name := range []string{
		"source-enhancement-packet", "source-base-packet", "source-cross-frame-burst",
	} {
		profile := mustCatalogProfile(t, extended, name)
		if len(profile.Bursts) != 1 ||
			profile.Bursts[0].SelectorType != matrixBurstSourceCoordinates ||
			len(profile.Bursts[0].SourceCoordinates) == 0 {
			t.Fatalf("source-coordinate profile %s = %#v", name, profile)
		}
	}

	for name, delay := range map[string]int{
		"age-15ms-outside":  20_000,
		"age-30ms-outside":  35_000,
		"age-60ms-outside":  65_000,
		"age-120ms-outside": 125_000,
	} {
		age := mustCatalogProfile(t, extended, name)
		if age.OneWayDelayMicroseconds != delay ||
			age.ExpectedOutcome != "keyframe-recovery" {
			t.Fatalf("age boundary profile %s = %#v", name, age)
		}
	}
	bandwidth := mustCatalogProfile(t, extended, "bandwidth-0.9x-q4")
	if bandwidth.BandwidthPermille != 900 || bandwidth.QueueFrames != 4 ||
		bandwidth.MeasuredFrames != 360 {
		t.Fatalf("bandwidth profile = %#v", bandwidth)
	}
	poorWAN := mustCatalogProfile(t, extended, "poor-wan-seed-65537")
	if poorWAN.OneWayDelayMicroseconds != 50_000 ||
		poorWAN.MaxJitterMicroseconds != 20_000 || poorWAN.MediaLossBasisPoints != 200 ||
		poorWAN.Seed == nil || *poorWAN.Seed != 65_537 ||
		len(poorWAN.Bursts) != 1 || poorWAN.Bursts[0].Length != 8 {
		t.Fatalf("poor WAN profile = %#v", poorWAN)
	}
	duplicate := mustCatalogProfile(t, extended, "dup-delayed-2pct-seed-8191")
	if duplicate.DelayedDuplicationBasisPoints != 200 ||
		duplicate.DuplicationDelayMinMicroseconds != 5_000 ||
		duplicate.DuplicationDelayMaxMicroseconds != 25_000 {
		t.Fatalf("delayed duplication profile = %#v", duplicate)
	}
}

func mustCatalogProfile(
	t *testing.T,
	profiles []recoveryMatrixProfile,
	name string,
) recoveryMatrixProfile {
	t.Helper()
	for _, profile := range profiles {
		if profile.Name == name {
			return profile
		}
	}
	t.Fatalf("profile %q not found", name)
	return recoveryMatrixProfile{}
}

func matrixCatalogWithProfiles(profiles ...string) string {
	return `{"schemaVersion":1,"profiles":[` + strings.Join(profiles, ",") + `]}`
}

func matrixMinimalProfileJSON(name string) string {
	return fmt.Sprintf(`{
		"name":%q,"tier":"fast","description":"fixture","seed":1741,
		"fps":60,"warmupFrames":1,"measuredFrames":1,"watchdogMilliseconds":1000,
		"nominalMediaBitsPerSecond":8000000,"keyframeSizeMultiplier":4,
		"rtxMaxAgeMilliseconds":30,"expectedOutcome":"clean",
		"requiredInvariants":["clean"]
	}`, name)
}

func matrixMinimalProfileWithJSON(name, fields string) string {
	profile := matrixMinimalProfileMap(name)
	overrides := map[string]any{}
	if err := json.Unmarshal([]byte(`{`+fields+`}`), &overrides); err != nil {
		panic(err)
	}
	for key, value := range overrides {
		profile[key] = value
	}
	encoded, err := json.Marshal(profile)
	if err != nil {
		panic(err)
	}
	return string(encoded)
}

func matrixMinimalProfileMap(name string) map[string]any {
	profile := map[string]any{}
	if err := json.Unmarshal([]byte(matrixMinimalProfileJSON(name)), &profile); err != nil {
		panic(err)
	}
	return profile
}

func mapsClone(source map[string]any) map[string]any {
	clone := make(map[string]any, len(source))
	for key, value := range source {
		clone[key] = value
	}
	return clone
}

func mustJSON(t *testing.T, value any) []byte {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func mapsEqual(left, right map[string]int) bool {
	if len(left) != len(right) {
		return false
	}
	for key, value := range left {
		if right[key] != value {
			return false
		}
	}
	return true
}

func mustWANProfile(
	t *testing.T,
	catalog WANRecoveryCatalog,
	id string,
) WANRecoveryProfile {
	t.Helper()
	for _, profile := range catalog.Profiles {
		if profile.ID == id {
			return profile
		}
	}
	t.Fatalf("WAN profile %q not found", id)
	return WANRecoveryProfile{}
}
