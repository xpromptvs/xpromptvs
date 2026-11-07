package main

import (
	"context"
	"fmt"
	"os"
	"regexp"
	"runtime"
	"strconv"
	"sync/atomic"
	"testing"
)

const recoveryMatrixMaximumDefaultParallelism = 8

func resolvedRecoveryMatrixParallelism(
	getenv func(string) string,
	gomaxprocs int,
) (int, error) {
	encoded := getenv("LLV_RECOVERY_MATRIX_PARALLELISM")
	if encoded != "" {
		if matched, _ := regexp.MatchString(`^[0-9]+$`, encoded); !matched {
			return 0, fmt.Errorf("invalid recovery matrix parallelism %q", encoded)
		}
		value, err := strconv.Atoi(encoded)
		if err != nil || value < 1 {
			return 0, fmt.Errorf("invalid recovery matrix parallelism %q", encoded)
		}
		return value, nil
	}
	if gomaxprocs < 1 {
		gomaxprocs = 1
	}
	return min(gomaxprocs, recoveryMatrixMaximumDefaultParallelism), nil
}

func TestRecoveryMatrixParallelismResolvesBoundedDefaultAndOverride(t *testing.T) {
	for _, test := range []struct {
		name       string
		encoded    string
		gomaxprocs int
		want       int
	}{
		{name: "single CPU", gomaxprocs: 1, want: 1},
		{name: "four CPUs", gomaxprocs: 4, want: 4},
		{name: "bounded default", gomaxprocs: 32, want: 8},
		{name: "override", encoded: "3", gomaxprocs: 32, want: 3},
	} {
		t.Run(test.name, func(t *testing.T) {
			got, err := resolvedRecoveryMatrixParallelism(
				matrixEnvironment(map[string]string{
					"LLV_RECOVERY_MATRIX_PARALLELISM": test.encoded,
				}),
				test.gomaxprocs,
			)
			if err != nil || got != test.want {
				t.Fatalf("parallelism = %d, %v; want %d", got, err, test.want)
			}
		})
	}
}

func TestRecoveryMatrixParallelismRejectsInvalidValues(t *testing.T) {
	for _, encoded := range []string{"0", "-1", "+2", "1.5", " 2", "2 ", "many"} {
		if _, err := resolvedRecoveryMatrixParallelism(
			matrixEnvironment(map[string]string{
				"LLV_RECOVERY_MATRIX_PARALLELISM": encoded,
			}),
			8,
		); err == nil {
			t.Fatalf("parallelism %q unexpectedly accepted", encoded)
		}
	}
}

func TestRecoveryMatrixProfilesRunConcurrentlyWithinBoundAndKeepOrder(t *testing.T) {
	profiles := []recoveryMatrixProfile{
		{Name: "first"},
		{Name: "second"},
		{Name: "third"},
		{Name: "fourth"},
	}
	var active atomic.Int32
	var peak atomic.Int32
	firstStarted := make(chan struct{})
	secondFinished := make(chan struct{})
	runner := func(_ context.Context, profile recoveryMatrixProfile) recoveryMatrixScenarioResult {
		current := active.Add(1)
		defer active.Add(-1)
		for previous := peak.Load(); current > previous &&
			!peak.CompareAndSwap(previous, current); previous = peak.Load() {
		}
		switch profile.Name {
		case "first":
			close(firstStarted)
			<-secondFinished
		case "second":
			<-firstStarted
			close(secondFinished)
		}
		return recoveryMatrixScenarioResult{Name: profile.Name}
	}

	results := runRecoveryMatrixProfilesWithRunner(t, profiles, 2, runner)
	if peak.Load() != 2 {
		t.Fatalf("peak concurrency = %d, want 2", peak.Load())
	}
	for index, profile := range profiles {
		if results[index].Name != profile.Name {
			t.Fatalf("result[%d] = %q, want %q", index, results[index].Name, profile.Name)
		}
	}
}

func runRecoveryMatrixProfiles(
	t *testing.T,
	profiles []recoveryMatrixProfile,
	parallelism int,
) []recoveryMatrixScenarioResult {
	t.Helper()
	return runRecoveryMatrixProfilesWithRunner(
		t,
		profiles,
		parallelism,
		runRecoveryMatrixScenario,
	)
}

func runRecoveryMatrixProfilesWithRunner(
	t *testing.T,
	profiles []recoveryMatrixProfile,
	parallelism int,
	runner func(context.Context, recoveryMatrixProfile) recoveryMatrixScenarioResult,
) []recoveryMatrixScenarioResult {
	t.Helper()
	results := make([]recoveryMatrixScenarioResult, len(profiles))
	semaphore := make(chan struct{}, parallelism)
	t.Run("profiles", func(t *testing.T) {
		for index, profile := range profiles {
			index, profile := index, profile
			t.Run(profile.Name, func(t *testing.T) {
				t.Parallel()
				semaphore <- struct{}{}
				defer func() { <-semaphore }()
				results[index] = runner(t.Context(), profile)
			})
		}
	})
	return results
}

func TestRecoveryNetworkMatrixFast(t *testing.T) {
	parallelism, err := resolvedRecoveryMatrixParallelism(os.Getenv, runtime.GOMAXPROCS(0))
	if err != nil {
		t.Fatal(err)
	}
	selected := os.Getenv("LLV_RECOVERY_MATRIX_PROFILE")
	profiles := mustResolvedRecoveryMatrixProfiles(t, matrixTierFast, selected, nil)
	if selected == "" && len(profiles) != 10 {
		t.Fatalf("fast profile count = %d", len(profiles))
	}
	results := runRecoveryMatrixProfiles(t, profiles, parallelism)
	for _, result := range results {
		if result.Status != matrixStatusPass {
			t.Errorf(
				"profile %s status=%s error=%s assertions=%#v",
				result.Name, result.Status, result.Error, result.Assertions,
			)
		}
	}
}

func mustResolvedRecoveryMatrixProfiles(
	t *testing.T,
	tier recoveryMatrixTier,
	name string,
	seedOverride *int64,
) []recoveryMatrixProfile {
	t.Helper()
	catalog, err := loadRecoveryMatrixCatalog(recoveryMatrixCatalogJSON)
	if err != nil {
		t.Fatal(err)
	}
	profiles, err := resolvedRecoveryMatrixProfiles(catalog, tier, name, seedOverride)
	if err != nil {
		t.Fatal(err)
	}
	return profiles
}
