package main

import (
	"errors"
	"fmt"
	"os"
	"regexp"
	"runtime"
	"slices"
	"strconv"
	"testing"
	"time"
)

type recoveryMatrixRunSelection struct {
	Tier         recoveryMatrixTier
	Profile      string
	SeedOverride *int64
	OutputPath   string
	Parallelism  int
}

func parseRecoveryMatrixRunSelection(
	getenv func(string) string,
) (recoveryMatrixRunSelection, error) {
	selection := recoveryMatrixRunSelection{
		Tier:       recoveryMatrixTier(getenv("LLV_RECOVERY_MATRIX_TIER")),
		Profile:    getenv("LLV_RECOVERY_MATRIX_PROFILE"),
		OutputPath: getenv("LLV_RECOVERY_MATRIX_OUTPUT"),
	}
	parallelism, err := resolvedRecoveryMatrixParallelism(getenv, runtime.GOMAXPROCS(0))
	if err != nil {
		return recoveryMatrixRunSelection{}, err
	}
	selection.Parallelism = parallelism
	if selection.Tier != "" && selection.Tier != matrixTierExtended {
		return recoveryMatrixRunSelection{}, fmt.Errorf("recovery matrix tier must be %q", matrixTierExtended)
	}
	if encodedSeed := getenv("LLV_RECOVERY_MATRIX_SEED"); encodedSeed != "" {
		if matched, _ := regexp.MatchString(`^[+-]?[0-9]+$`, encodedSeed); !matched {
			return recoveryMatrixRunSelection{}, fmt.Errorf("invalid recovery matrix seed %q", encodedSeed)
		}
		seed, err := strconv.ParseInt(encodedSeed, 10, 64)
		if err != nil {
			return recoveryMatrixRunSelection{}, fmt.Errorf("invalid recovery matrix seed %q: %w", encodedSeed, err)
		}
		selection.SeedOverride = &seed
	}
	return selection, nil
}

func TestRecoveryNetworkMatrixExtended(t *testing.T) {
	selection, err := parseRecoveryMatrixRunSelection(os.Getenv)
	if err != nil {
		t.Fatal(err)
	}
	if selection.Tier != matrixTierExtended {
		t.Skip("set LLV_RECOVERY_MATRIX_TIER=extended to run the extended matrix")
	}
	catalog, err := loadRecoveryMatrixCatalog(recoveryMatrixCatalogJSON)
	if err != nil {
		t.Fatal(err)
	}
	profiles, err := resolvedRecoveryMatrixProfiles(
		catalog, matrixTierExtended, selection.Profile, selection.SeedOverride,
	)
	if err != nil {
		t.Fatal(err)
	}
	started := time.Now().UTC()
	var results []recoveryMatrixScenarioResult
	if selection.OutputPath != "" {
		defer func() {
			if err := writeRecoveryMatrixEvidence(
				selection, catalog, started, results, os.Getenv,
			); err != nil {
				t.Errorf("write recovery matrix evidence: %v", err)
			}
		}()
	}
	results = runRecoveryMatrixProfiles(t, profiles, selection.Parallelism)
	for _, result := range results {
		if result.Status != matrixStatusPass {
			t.Errorf(
				"profile %s status=%s error=%s assertions=%#v",
				result.Name, result.Status, result.Error, result.Assertions,
			)
		}
	}
}

func writeRecoveryMatrixEvidence(
	selection recoveryMatrixRunSelection,
	catalog recoveryMatrixCatalog,
	started time.Time,
	results []recoveryMatrixScenarioResult,
	getenv func(string) string,
) error {
	metadata, metadataError := recoveryMatrixEvidenceMetadataFromEnvironment(getenv)
	if metadataError != nil {
		for index := range results {
			results[index].Error = metadataError.Error()
			results[index] = evaluateRecoveryMatrixResult(results[index])
		}
	}
	report := recoveryMatrixReport{
		SchemaVersion: 1, CatalogSchemaVersion: catalog.SchemaVersion,
		Parallelism:    selection.Parallelism,
		SourceRevision: metadata.revision, SourceDirty: metadata.dirty,
		GoVersion: runtime.Version(), PionWebRTCVersion: pionWebRTCVersion,
		PionTransportVersion: pionTransportVersion, Tier: matrixTierExtended,
		StartedAtUTC:    started.Format(time.RFC3339Nano),
		FinishedAtUTC:   time.Now().UTC().Format(time.RFC3339Nano),
		CatalogSHA256:   metadata.catalogSHA256,
		HostDescription: metadata.hostDescription,
		Command:         recoveryMatrixReportCommand(selection), Results: results,
	}
	if err := writeRecoveryMatrixReport(selection.OutputPath, report); err != nil {
		return err
	}
	return metadataError
}

type recoveryMatrixEvidenceMetadata struct {
	revision        string
	dirty           bool
	catalogSHA256   string
	hostDescription string
}

var recoveryMatrixSHA256Pattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

func recoveryMatrixEvidenceMetadataFromEnvironment(
	getenv func(string) string,
) (recoveryMatrixEvidenceMetadata, error) {
	metadata := recoveryMatrixEvidenceMetadata{
		revision:        getenv("LLV_RECOVERY_MATRIX_REVISION"),
		catalogSHA256:   getenv("LLV_RECOVERY_MATRIX_CATALOG_SHA256"),
		hostDescription: getenv("LLV_RECOVERY_MATRIX_HOST_DESCRIPTION"),
	}
	if metadata.revision == "" || metadata.hostDescription == "" ||
		!recoveryMatrixSHA256Pattern.MatchString(metadata.catalogSHA256) {
		return metadata, errors.New("missing or malformed recovery matrix evidence metadata")
	}
	switch dirty := getenv("LLV_RECOVERY_MATRIX_DIRTY"); dirty {
	case "true":
		metadata.dirty = true
	case "false":
		metadata.dirty = false
	default:
		return metadata, fmt.Errorf("invalid recovery matrix dirty flag %q", dirty)
	}
	return metadata, nil
}

func recoveryMatrixReportCommand(selection recoveryMatrixRunSelection) []string {
	command := []string{"scripts/run-recovery-network-matrix.sh"}
	if selection.Profile != "" {
		command = append(command, "--profile", selection.Profile)
	}
	if selection.SeedOverride != nil {
		command = append(command, "--seed", strconv.FormatInt(*selection.SeedOverride, 10))
	}
	command = append(command, "--parallel", strconv.Itoa(selection.Parallelism))
	if selection.OutputPath != "" {
		command = append(command, "--output", selection.OutputPath)
	}
	return command
}

func TestRecoveryMatrixExtendedSelectionParsesStrictly(t *testing.T) {
	selection, err := parseRecoveryMatrixRunSelection(matrixEnvironment(map[string]string{}))
	if err != nil || selection.Tier != "" || selection.Profile != "" ||
		selection.SeedOverride != nil || selection.Parallelism < 1 || selection.Parallelism > 8 {
		t.Fatalf("empty selection = %#v, %v", selection, err)
	}
	selection, err = parseRecoveryMatrixRunSelection(matrixEnvironment(map[string]string{
		"LLV_RECOVERY_MATRIX_TIER":        "extended",
		"LLV_RECOVERY_MATRIX_PROFILE":     "poor-wan-seed-1741",
		"LLV_RECOVERY_MATRIX_SEED":        "+8191",
		"LLV_RECOVERY_MATRIX_OUTPUT":      "/tmp/matrix.json",
		"LLV_RECOVERY_MATRIX_PARALLELISM": "3",
	}))
	if err != nil || selection.Tier != matrixTierExtended ||
		selection.Profile != "poor-wan-seed-1741" || selection.SeedOverride == nil ||
		*selection.SeedOverride != 8191 || selection.OutputPath != "/tmp/matrix.json" ||
		selection.Parallelism != 3 {
		t.Fatalf("resolved selection = %#v, %v", selection, err)
	}
	for _, seed := range []string{"1.5", " 1", "1 ", "0x10", "--1"} {
		_, err := parseRecoveryMatrixRunSelection(matrixEnvironment(map[string]string{
			"LLV_RECOVERY_MATRIX_TIER": "extended",
			"LLV_RECOVERY_MATRIX_SEED": seed,
		}))
		if err == nil {
			t.Fatalf("seed %q unexpectedly accepted", seed)
		}
	}
	if _, err := parseRecoveryMatrixRunSelection(matrixEnvironment(map[string]string{
		"LLV_RECOVERY_MATRIX_TIER": "fast",
	})); err == nil {
		t.Fatal("non-extended explicit tier unexpectedly accepted")
	}
	for _, parallelism := range []string{"0", "-1", "+2", "1.5", " 2", "2 ", "many"} {
		if _, err := parseRecoveryMatrixRunSelection(matrixEnvironment(map[string]string{
			"LLV_RECOVERY_MATRIX_PARALLELISM": parallelism,
		})); err == nil {
			t.Fatalf("parallelism %q unexpectedly accepted by selection", parallelism)
		}
	}
}

func TestRecoveryMatrixExtendedSelectionAllowsExactFastProfileAndValidatesSeedUse(t *testing.T) {
	catalog, err := loadRecoveryMatrixCatalog(recoveryMatrixCatalogJSON)
	if err != nil {
		t.Fatal(err)
	}
	seed := int64(1741)
	profiles, err := resolvedRecoveryMatrixProfiles(catalog, matrixTierExtended, "random-loss-1pct", &seed)
	if err != nil || len(profiles) != 1 || profiles[0].Tier != matrixTierFast || *profiles[0].Seed != seed {
		t.Fatalf("exact fast replay = %#v, %v", profiles, err)
	}
	if _, err := resolvedRecoveryMatrixProfiles(catalog, matrixTierExtended, "clean", &seed); err == nil {
		t.Fatal("seed override on deterministic profile unexpectedly accepted")
	}
	if _, err := resolvedRecoveryMatrixProfiles(catalog, matrixTierExtended, "", &seed); err == nil {
		t.Fatal("seed override on multi-profile selection unexpectedly accepted")
	}
}

func TestRecoveryMatrixExtendedSelectionBuildsEvidenceMetadataAndCommand(t *testing.T) {
	metadata, err := recoveryMatrixEvidenceMetadataFromEnvironment(matrixEnvironment(map[string]string{
		"LLV_RECOVERY_MATRIX_REVISION":         "abc123",
		"LLV_RECOVERY_MATRIX_DIRTY":            "false",
		"LLV_RECOVERY_MATRIX_CATALOG_SHA256":   "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		"LLV_RECOVERY_MATRIX_HOST_DESCRIPTION": "test host",
	}))
	if err != nil || metadata.revision != "abc123" || metadata.dirty ||
		metadata.hostDescription != "test host" {
		t.Fatalf("metadata = %#v, %v", metadata, err)
	}
	seed := int64(-17)
	selection := recoveryMatrixRunSelection{
		Tier: matrixTierExtended, Profile: "random-loss-1pct",
		SeedOverride: &seed, OutputPath: "/tmp/report.json", Parallelism: 3,
	}
	want := []string{
		"scripts/run-recovery-network-matrix.sh", "--profile", "random-loss-1pct",
		"--seed", "-17", "--parallel", "3", "--output", "/tmp/report.json",
	}
	if got := recoveryMatrixReportCommand(selection); !slices.Equal(got, want) {
		t.Fatalf("command = %q, want %q", got, want)
	}
	for name, values := range map[string]map[string]string{
		"missing": {},
		"bad dirty": {
			"LLV_RECOVERY_MATRIX_REVISION": "abc", "LLV_RECOVERY_MATRIX_DIRTY": "1",
			"LLV_RECOVERY_MATRIX_CATALOG_SHA256":   "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
			"LLV_RECOVERY_MATRIX_HOST_DESCRIPTION": "host",
		},
		"bad digest": {
			"LLV_RECOVERY_MATRIX_REVISION": "abc", "LLV_RECOVERY_MATRIX_DIRTY": "true",
			"LLV_RECOVERY_MATRIX_CATALOG_SHA256": "ABC", "LLV_RECOVERY_MATRIX_HOST_DESCRIPTION": "host",
		},
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := recoveryMatrixEvidenceMetadataFromEnvironment(matrixEnvironment(values)); err == nil {
				t.Fatal("malformed metadata unexpectedly accepted")
			}
		})
	}
}

func TestRecoveryMatrixVirtualFluidOverflowRecoversAndDrains(t *testing.T) {
	profile := mustRecoveryMatrixProfile(t, "bandwidth-0.9x-q1")
	profile.WarmupFrames = 5
	profile.MeasuredFrames = 120
	result := runRecoveryMatrixScenario(t.Context(), profile)
	admitted := result.Metrics.Impairment.AdmittedToVNet[matrixPacketOriginal]
	delivered := result.Metrics.Impairment.Delivered[matrixPacketOriginal]
	dropped := result.Metrics.Impairment.EffectiveQueueDropped[matrixPacketOriginal]
	if admitted.Packets <= delivered.Packets || dropped.Packets == 0 || dropped.Bytes == 0 {
		t.Fatalf("virtual-fluid loss accounting admitted=%#v delivered=%#v dropped=%#v error=%q snapshot=%#v", admitted, delivered, dropped, result.Error, result.Metrics.Impairment)
	}
	if result.Metrics.Impairment.OutstandingMediaBytesCurrent != 0 ||
		result.Metrics.FramesResumedAfterRecovery == 0 || result.Status != matrixStatusPass {
		t.Fatalf("virtual-fluid recovery result = %#v", result)
	}
}

func matrixEnvironment(values map[string]string) func(string) string {
	return func(name string) string { return values[name] }
}
