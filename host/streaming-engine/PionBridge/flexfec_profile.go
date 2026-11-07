package main

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"fmt"
	"io"
	"slices"
	"sort"
)

type FlexFECMatrixCase struct {
	Name                        string                `json:"name"`
	Tier                        RecoveryMatrixTier    `json:"tier"`
	Seeds                       []int64               `json:"seeds"`
	FPS                         int                   `json:"fps"`
	MeasurementMode             string                `json:"measurementMode"`
	TotalRTPBudgetBitsPerSecond uint32                `json:"totalRtpBudgetBitsPerSecond"`
	ScalabilityModes            []string              `json:"scalabilityModes"`
	Impairment                  RecoveryMatrixProfile `json:"impairment"`
}

type FlexFECMatrixCatalog struct {
	SchemaVersion int                 `json:"schemaVersion"`
	Cases         []FlexFECMatrixCase `json:"cases"`
}

//go:embed testdata/flexfec_impairment_profiles.json
var flexFECMatrixCatalogJSON []byte

func loadFlexFECMatrixCatalog(data []byte) (FlexFECMatrixCatalog, error) {
	if len(data) == 0 {
		data = flexFECMatrixCatalogJSON
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var catalog FlexFECMatrixCatalog
	if err := decoder.Decode(&catalog); err != nil {
		return FlexFECMatrixCatalog{}, fmt.Errorf("decode FlexFEC matrix catalog: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return FlexFECMatrixCatalog{}, fmt.Errorf("decode FlexFEC matrix catalog: trailing value")
		}
		return FlexFECMatrixCatalog{}, fmt.Errorf("decode FlexFEC matrix catalog: %w", err)
	}
	if err := validateFlexFECMatrixCatalog(catalog); err != nil {
		return FlexFECMatrixCatalog{}, err
	}
	return cloneFlexFECMatrixCatalog(catalog), nil
}

func validateFlexFECMatrixCatalog(catalog FlexFECMatrixCatalog) error {
	if catalog.SchemaVersion != 1 || len(catalog.Cases) == 0 {
		return fmt.Errorf("invalid FlexFEC matrix schema or empty catalog")
	}
	seen := make(map[string]struct{}, len(catalog.Cases))
	for _, candidate := range catalog.Cases {
		if candidate.Name == "" {
			return fmt.Errorf("FlexFEC matrix case has no name")
		}
		if _, exists := seen[candidate.Name]; exists {
			return fmt.Errorf("duplicate FlexFEC matrix case %q", candidate.Name)
		}
		seen[candidate.Name] = struct{}{}
		if candidate.Tier != matrixTierFast && candidate.Tier != matrixTierExtended {
			return fmt.Errorf("case %q has invalid tier", candidate.Name)
		}
		if candidate.FPS != 60 || candidate.MeasurementMode != "rtt-primed" ||
			candidate.TotalRTPBudgetBitsPerSecond != 8_000_000 ||
			!slices.Equal(candidate.ScalabilityModes, []string{"L1T1", "L1T3"}) {
			return fmt.Errorf("case %q has invalid measurement identity", candidate.Name)
		}
		profile := candidate.Impairment
		if profile.SchemaVersion != 2 || profile.Name != candidate.Name ||
			profile.Tier != candidate.Tier || profile.FPS != candidate.FPS ||
			profile.NominalMediaBitsPerSecond != int(candidate.TotalRTPBudgetBitsPerSecond) ||
			profile.Seed != nil {
			return fmt.Errorf("case %q has inconsistent impairment identity", candidate.Name)
		}
		probabilistic := profile.isProbabilistic()
		if probabilistic && !slices.Equal(candidate.Seeds, []int64{1741, 8191, 65537}) {
			return fmt.Errorf("case %q has incomplete probabilistic seeds", candidate.Name)
		}
		if !probabilistic && len(candidate.Seeds) != 0 {
			return fmt.Errorf("case %q assigns seeds to deterministic impairment", candidate.Name)
		}
		if probabilistic {
			for _, seed := range candidate.Seeds {
				seeded := cloneRecoveryMatrixProfile(profile)
				seeded.Seed = new(int64)
				*seeded.Seed = seed
				if err := validateRecoveryMatrixProfile(seeded); err != nil {
					return fmt.Errorf("case %q seed %d: %w", candidate.Name, seed, err)
				}
			}
		} else if err := validateRecoveryMatrixProfile(profile); err != nil {
			return fmt.Errorf("case %q: %w", candidate.Name, err)
		}
	}
	return nil
}

func resolvedFlexFECMatrixCases(
	catalog FlexFECMatrixCatalog,
	tier RecoveryMatrixTier,
) []FlexFECMatrixCase {
	var result []FlexFECMatrixCase
	for _, candidate := range catalog.Cases {
		if tier == matrixTierExtended || candidate.Tier == matrixTierFast {
			result = append(result, cloneFlexFECMatrixCase(candidate))
		}
	}
	sort.Slice(result, func(left, right int) bool {
		return result[left].Name < result[right].Name
	})
	return result
}

func cloneFlexFECMatrixCatalog(source FlexFECMatrixCatalog) FlexFECMatrixCatalog {
	cloned := FlexFECMatrixCatalog{
		SchemaVersion: source.SchemaVersion,
		Cases:         make([]FlexFECMatrixCase, len(source.Cases)),
	}
	for index := range source.Cases {
		cloned.Cases[index] = cloneFlexFECMatrixCase(source.Cases[index])
	}
	return cloned
}

func cloneFlexFECMatrixCase(source FlexFECMatrixCase) FlexFECMatrixCase {
	cloned := source
	cloned.Seeds = append([]int64(nil), source.Seeds...)
	cloned.ScalabilityModes = append([]string(nil), source.ScalabilityModes...)
	cloned.Impairment = cloneRecoveryMatrixProfile(source.Impairment)
	return cloned
}
