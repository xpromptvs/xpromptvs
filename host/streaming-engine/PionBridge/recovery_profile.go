package main

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"time"
)

type RecoveryMatrixTier string

const (
	matrixTierFast     RecoveryMatrixTier = "fast"
	matrixTierExtended RecoveryMatrixTier = "extended"
)

type RecoveryMatrixBurst struct {
	SelectorType         string                           `json:"selectorType,omitempty"`
	StartOriginalOrdinal uint64                           `json:"startOriginalOrdinal,omitempty"`
	Length               uint64                           `json:"length,omitempty"`
	SourceCoordinates    []RecoveryMatrixSourceCoordinate `json:"sourceCoordinates,omitempty"`
}

type RecoveryMatrixSourceCoordinate struct {
	FrameOrdinal uint64 `json:"frameOrdinal"`
	PacketIndex  uint64 `json:"packetIndex"`
}

const matrixBurstSourceCoordinates = "source-coordinates"

type RecoveryMatrixProfile struct {
	SchemaVersion                   int                   `json:"schemaVersion,omitempty"`
	Name                            string                `json:"name"`
	Tier                            RecoveryMatrixTier    `json:"tier"`
	Description                     string                `json:"description"`
	Seed                            *int64                `json:"seed"`
	FPS                             int                   `json:"fps"`
	WarmupFrames                    int                   `json:"warmupFrames"`
	MeasuredFrames                  int                   `json:"measuredFrames"`
	WatchdogMilliseconds            int                   `json:"watchdogMilliseconds"`
	NominalMediaBitsPerSecond       int                   `json:"nominalMediaBitsPerSecond"`
	KeyframeSizeMultiplier          int                   `json:"keyframeSizeMultiplier"`
	OneWayDelayMicroseconds         int                   `json:"oneWayDelayMicroseconds"`
	MaxJitterMicroseconds           int                   `json:"maxJitterMicroseconds"`
	MediaLossBasisPoints            int                   `json:"mediaLossBasisPoints"`
	FECLossBasisPoints              int                   `json:"fecLossBasisPoints"`
	NACKLossBasisPoints             int                   `json:"nackLossBasisPoints"`
	RTXLossBasisPoints              int                   `json:"rtxLossBasisPoints"`
	TWCCLossBasisPoints             int                   `json:"twccLossBasisPoints"`
	DropFirstFEC                    bool                  `json:"dropFirstFec"`
	DropFirstNACK                   bool                  `json:"dropFirstNack"`
	DropFirstRTX                    bool                  `json:"dropFirstRtx"`
	DropFirstTWCC                   bool                  `json:"dropFirstTwcc"`
	Bursts                          []RecoveryMatrixBurst `json:"bursts"`
	ImmediateDuplicationBasisPoints int                   `json:"immediateDuplicationBasisPoints"`
	DelayedDuplicationBasisPoints   int                   `json:"delayedDuplicationBasisPoints"`
	DuplicationDelayMinMicroseconds int                   `json:"duplicationDelayMinMicroseconds"`
	DuplicationDelayMaxMicroseconds int                   `json:"duplicationDelayMaxMicroseconds"`
	BandwidthPermille               int                   `json:"bandwidthPermille"`
	BandwidthDurationMilliseconds   int                   `json:"bandwidthDurationMilliseconds"`
	QueueFrames                     int                   `json:"queueFrames"`
	RTXMaxAgeMilliseconds           int                   `json:"rtxMaxAgeMilliseconds"`
	ExpectedOutcome                 string                `json:"expectedOutcome"`
	RequiredInvariants              []string              `json:"requiredInvariants"`
	rtxMaxAgePresent                bool
}

func (profile *RecoveryMatrixProfile) UnmarshalJSON(data []byte) error {
	type plainProfile RecoveryMatrixProfile
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var decoded plainProfile
	if err := decoder.Decode(&decoded); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return fmt.Errorf("trailing value")
		}
		return err
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return err
	}
	*profile = RecoveryMatrixProfile(decoded)
	_, profile.rtxMaxAgePresent = fields["rtxMaxAgeMilliseconds"]
	return nil
}

type RecoveryMatrixCatalog struct {
	SchemaVersion int                     `json:"schemaVersion"`
	Profiles      []RecoveryMatrixProfile `json:"profiles"`
}

//go:embed testdata/recovery_impairment_profiles.json
var recoveryMatrixCatalogJSON []byte

type WANRecoveryProfile struct {
	ID                          string                `json:"id"`
	Family                      string                `json:"family"`
	Seeds                       []int64               `json:"seeds"`
	FPS                         int                   `json:"fps"`
	MeasurementMode             string                `json:"measurementMode"`
	RTTPrimingMilliseconds      int                   `json:"rttPrimingMilliseconds"`
	TotalRTPBudgetBitsPerSecond int                   `json:"totalRtpBudgetBitsPerSecond"`
	ScalabilityModes            []string              `json:"scalabilityModes"`
	Impairment                  RecoveryMatrixProfile `json:"impairment"`
}

type WANRecoveryCatalog struct {
	SchemaVersion int                  `json:"schemaVersion"`
	Profiles      []WANRecoveryProfile `json:"profiles"`
}

type WANRTXAgeCandidate struct {
	ID                    string `json:"id"`
	Mode                  string `json:"mode"`
	RTXMaxAgeMilliseconds int    `json:"rtxMaxAgeMilliseconds"`
	MultiplierMilli       int    `json:"multiplierMilli"`
	CapMilliseconds       int    `json:"capMilliseconds"`
}

type WANRTXAgeCandidateCatalog struct {
	SchemaVersion int                  `json:"schemaVersion"`
	Candidates    []WANRTXAgeCandidate `json:"candidates"`
}

//go:embed testdata/wan_recovery_profiles.json
var wanRecoveryCatalogJSON []byte

//go:embed testdata/wan_rtx_age_candidates.json
var wanRTXAgeCandidatesJSON []byte

func loadWANRecoveryCatalog(data []byte) (WANRecoveryCatalog, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var catalog WANRecoveryCatalog
	if err := decoder.Decode(&catalog); err != nil {
		return WANRecoveryCatalog{}, fmt.Errorf("decode WAN recovery catalog: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return WANRecoveryCatalog{}, fmt.Errorf("decode WAN recovery catalog: trailing value")
	}
	if catalog.SchemaVersion != 1 || len(catalog.Profiles) == 0 {
		return WANRecoveryCatalog{}, fmt.Errorf("invalid WAN recovery catalog identity")
	}
	seen := make(map[string]struct{}, len(catalog.Profiles))
	for index := range catalog.Profiles {
		profile := &catalog.Profiles[index]
		if profile.ID == "" || profile.Family == "" {
			return WANRecoveryCatalog{}, fmt.Errorf("WAN profile %d has no identity", index)
		}
		if _, exists := seen[profile.ID]; exists {
			return WANRecoveryCatalog{}, fmt.Errorf("duplicate WAN profile %q", profile.ID)
		}
		seen[profile.ID] = struct{}{}
		validation := profile.Impairment
		if validation.isProbabilistic() {
			if len(profile.Seeds) == 0 {
				return WANRecoveryCatalog{}, fmt.Errorf("probabilistic WAN profile %q has no seeds", profile.ID)
			}
			validation.Seed = &profile.Seeds[0]
		} else if len(profile.Seeds) != 0 {
			return WANRecoveryCatalog{}, fmt.Errorf("deterministic WAN profile %q has seeds", profile.ID)
		}
		if err := validateRecoveryMatrixProfile(validation); err != nil {
			return WANRecoveryCatalog{}, fmt.Errorf("WAN profile %q: %w", profile.ID, err)
		}
	}
	return catalog, nil
}

func loadWANRTXAgeCandidates(data []byte) (WANRTXAgeCandidateCatalog, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var catalog WANRTXAgeCandidateCatalog
	if err := decoder.Decode(&catalog); err != nil {
		return WANRTXAgeCandidateCatalog{}, fmt.Errorf("decode WAN RTX candidates: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return WANRTXAgeCandidateCatalog{}, fmt.Errorf("decode WAN RTX candidates: trailing value")
	}
	if catalog.SchemaVersion != 1 || len(catalog.Candidates) == 0 {
		return WANRTXAgeCandidateCatalog{}, fmt.Errorf("invalid WAN RTX candidate identity")
	}
	seen := make(map[string]struct{}, len(catalog.Candidates))
	for _, candidate := range catalog.Candidates {
		if candidate.ID == "" {
			return WANRTXAgeCandidateCatalog{}, fmt.Errorf("WAN RTX candidate has no ID")
		}
		if _, exists := seen[candidate.ID]; exists {
			return WANRTXAgeCandidateCatalog{}, fmt.Errorf("duplicate WAN RTX candidate %q", candidate.ID)
		}
		seen[candidate.ID] = struct{}{}
		config := RTXAgePolicyConfig{
			Floor:           time.Duration(candidate.RTXMaxAgeMilliseconds) * time.Millisecond,
			Cap:             time.Duration(candidate.CapMilliseconds) * time.Millisecond,
			MultiplierMilli: uint32(candidate.MultiplierMilli),
		}
		var mediaRTT *mediaRTTEstimator
		switch candidate.Mode {
		case "fixed":
			config.Mode = RTXAgeFixed
		case "rtt":
			config.Mode = RTXAgeRTT
			mediaRTT = &mediaRTTEstimator{}
		default:
			return WANRTXAgeCandidateCatalog{}, fmt.Errorf("candidate %q has invalid mode", candidate.ID)
		}
		if _, err := NewRTXAgePolicy(config, mediaRTT); err != nil {
			return WANRTXAgeCandidateCatalog{}, fmt.Errorf("candidate %q: %w", candidate.ID, err)
		}
	}
	return catalog, nil
}

func parseRecoveryMatrixProfile(data []byte) (RecoveryMatrixProfile, error) {
	return parseRecoveryMatrixProfileWithSeed(data, nil)
}

func parseRecoveryMatrixProfileWithSeed(
	data []byte,
	seedOverride *int64,
) (RecoveryMatrixProfile, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var profile RecoveryMatrixProfile
	if err := decoder.Decode(&profile); err != nil {
		return RecoveryMatrixProfile{}, fmt.Errorf("decode recovery impairment profile: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return RecoveryMatrixProfile{}, fmt.Errorf("decode recovery impairment profile: trailing value")
		}
		return RecoveryMatrixProfile{}, fmt.Errorf("decode recovery impairment profile: %w", err)
	}
	if seedOverride != nil {
		profile.Seed = new(int64)
		*profile.Seed = *seedOverride
	}
	if err := validateRecoveryMatrixProfile(profile); err != nil {
		return RecoveryMatrixProfile{}, fmt.Errorf("invalid recovery impairment profile: %w", err)
	}
	return profile, nil
}

func loadRecoveryMatrixCatalog(data []byte) (RecoveryMatrixCatalog, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var catalog RecoveryMatrixCatalog
	if err := decoder.Decode(&catalog); err != nil {
		return RecoveryMatrixCatalog{}, fmt.Errorf("decode recovery matrix catalog: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return RecoveryMatrixCatalog{}, fmt.Errorf("decode recovery matrix catalog: trailing value")
		}
		return RecoveryMatrixCatalog{}, fmt.Errorf("decode recovery matrix catalog: %w", err)
	}
	if catalog.SchemaVersion != 1 {
		return RecoveryMatrixCatalog{}, fmt.Errorf(
			"recovery matrix catalog schema = %d, want 1", catalog.SchemaVersion,
		)
	}
	seen := make(map[string]struct{}, len(catalog.Profiles))
	for index := range catalog.Profiles {
		profile := &catalog.Profiles[index]
		if _, exists := seen[profile.Name]; exists {
			return RecoveryMatrixCatalog{}, fmt.Errorf("duplicate recovery matrix profile %q", profile.Name)
		}
		seen[profile.Name] = struct{}{}
		if err := validateRecoveryMatrixProfile(*profile); err != nil {
			return RecoveryMatrixCatalog{}, fmt.Errorf("profile %q: %w", profile.Name, err)
		}
	}
	return catalog, nil
}

func validateRecoveryMatrixProfile(profile RecoveryMatrixProfile) error {
	if profile.SchemaVersion != 0 && profile.SchemaVersion != 2 && profile.SchemaVersion != 3 {
		return fmt.Errorf("invalid profile schema %d", profile.SchemaVersion)
	}
	if profile.SchemaVersion == 3 {
		if profile.rtxMaxAgePresent {
			return fmt.Errorf("schema 3 embeds RTX recovery policy")
		}
	} else if !profile.rtxMaxAgePresent {
		return fmt.Errorf("schema %d omits RTX recovery policy", profile.SchemaVersion)
	}
	if profile.Name == "" || profile.Description == "" {
		return fmt.Errorf("name and description must be nonempty")
	}
	if profile.Tier != matrixTierFast && profile.Tier != matrixTierExtended {
		return fmt.Errorf("invalid tier %q", profile.Tier)
	}
	if profile.FPS <= 0 || profile.WarmupFrames < 0 || profile.MeasuredFrames <= 0 ||
		profile.WatchdogMilliseconds <= 0 || profile.NominalMediaBitsPerSecond <= 0 ||
		profile.KeyframeSizeMultiplier <= 0 || profile.OneWayDelayMicroseconds < 0 ||
		profile.MaxJitterMicroseconds < 0 ||
		(profile.SchemaVersion != 3 && (profile.RTXMaxAgeMilliseconds < 1 ||
			profile.RTXMaxAgeMilliseconds > 1_000)) {
		return fmt.Errorf("invalid timing, pacing, or media configuration")
	}
	for _, value := range []int{
		profile.MediaLossBasisPoints, profile.FECLossBasisPoints,
		profile.NACKLossBasisPoints, profile.RTXLossBasisPoints,
		profile.TWCCLossBasisPoints, profile.ImmediateDuplicationBasisPoints,
		profile.DelayedDuplicationBasisPoints,
	} {
		if value < 0 || value > 10_000 {
			return fmt.Errorf("probability %d is outside 0...10000 basis points", value)
		}
	}
	if profile.DuplicationDelayMinMicroseconds < 0 ||
		profile.DuplicationDelayMaxMicroseconds < profile.DuplicationDelayMinMicroseconds {
		return fmt.Errorf("invalid duplication delay range")
	}
	if profile.MaxJitterMicroseconds > 0 &&
		(profile.ImmediateDuplicationBasisPoints > 0 || profile.DelayedDuplicationBasisPoints > 0) {
		return fmt.Errorf("jitter and duplication cannot share one profile")
	}
	if profile.BandwidthPermille < 0 || profile.BandwidthDurationMilliseconds < 0 ||
		(profile.BandwidthPermille > 0 && profile.QueueFrames < 1) ||
		(profile.BandwidthPermille == 0 &&
			(profile.QueueFrames != 0 || profile.BandwidthDurationMilliseconds != 0)) {
		return fmt.Errorf("invalid bandwidth queue configuration")
	}
	for _, burst := range profile.Bursts {
		switch burst.SelectorType {
		case "":
			if burst.StartOriginalOrdinal == 0 || burst.Length == 0 ||
				len(burst.SourceCoordinates) != 0 {
				return fmt.Errorf("invalid legacy ordinal burst %#v", burst)
			}
		case matrixBurstSourceCoordinates:
			if burst.StartOriginalOrdinal != 0 || burst.Length != 0 ||
				len(burst.SourceCoordinates) == 0 {
				return fmt.Errorf("invalid source-coordinate selector %#v", burst)
			}
			seenCoordinates := make(map[RecoveryMatrixSourceCoordinate]struct{}, len(burst.SourceCoordinates))
			for _, coordinate := range burst.SourceCoordinates {
				if coordinate.FrameOrdinal == 0 || coordinate.PacketIndex == 0 {
					return fmt.Errorf("invalid source coordinate %#v", coordinate)
				}
				if _, exists := seenCoordinates[coordinate]; exists {
					return fmt.Errorf("duplicate source coordinate %#v", coordinate)
				}
				seenCoordinates[coordinate] = struct{}{}
			}
		default:
			return fmt.Errorf("invalid burst selector type %q", burst.SelectorType)
		}
	}
	if profile.ExpectedOutcome == "" || len(profile.RequiredInvariants) == 0 {
		return fmt.Errorf("missing outcome or invariants")
	}
	if profile.isProbabilistic() && profile.Seed == nil {
		return fmt.Errorf("probabilistic profile has no seed")
	}
	return nil
}

func (profile RecoveryMatrixProfile) isProbabilistic() bool {
	return profile.MaxJitterMicroseconds > 0 || profile.MediaLossBasisPoints > 0 ||
		profile.FECLossBasisPoints > 0 || profile.NACKLossBasisPoints > 0 ||
		profile.RTXLossBasisPoints > 0 || profile.TWCCLossBasisPoints > 0 ||
		profile.ImmediateDuplicationBasisPoints > 0 ||
		profile.DelayedDuplicationBasisPoints > 0
}

func resolvedRecoveryMatrixProfiles(
	catalog RecoveryMatrixCatalog,
	tier RecoveryMatrixTier,
	name string,
	seedOverride *int64,
) ([]RecoveryMatrixProfile, error) {
	var profiles []RecoveryMatrixProfile
	for _, candidate := range catalog.Profiles {
		if name != "" {
			if candidate.Name == name {
				profiles = append(profiles, cloneRecoveryMatrixProfile(candidate))
			}
			continue
		}
		if candidate.Tier == tier {
			profiles = append(profiles, cloneRecoveryMatrixProfile(candidate))
		}
	}
	if name != "" && len(profiles) == 0 {
		return nil, fmt.Errorf("unknown recovery matrix profile %q", name)
	}
	if seedOverride != nil {
		if len(profiles) != 1 || !profiles[0].isProbabilistic() {
			return nil, fmt.Errorf("seed override requires one probabilistic profile")
		}
		seed := *seedOverride
		profiles[0].Seed = &seed
	}
	sort.Slice(profiles, func(left, right int) bool {
		return profiles[left].Name < profiles[right].Name
	})
	return profiles, nil
}

func cloneRecoveryMatrixProfile(profile RecoveryMatrixProfile) RecoveryMatrixProfile {
	cloned := profile
	if profile.Seed != nil {
		seed := *profile.Seed
		cloned.Seed = &seed
	}
	cloned.Bursts = make([]RecoveryMatrixBurst, len(profile.Bursts))
	for index, burst := range profile.Bursts {
		cloned.Bursts[index] = burst
		cloned.Bursts[index].SourceCoordinates = append(
			[]RecoveryMatrixSourceCoordinate(nil), burst.SourceCoordinates...,
		)
	}
	cloned.RequiredInvariants = append([]string(nil), profile.RequiredInvariants...)
	return cloned
}

// Package-local aliases keep the retained matrix orchestration source-compatible.
type recoveryMatrixTier = RecoveryMatrixTier
type recoveryMatrixBurst = RecoveryMatrixBurst
type recoveryMatrixSourceCoordinate = RecoveryMatrixSourceCoordinate
type recoveryMatrixProfile = RecoveryMatrixProfile
type recoveryMatrixCatalog = RecoveryMatrixCatalog
