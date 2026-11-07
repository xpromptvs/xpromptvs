package main

import (
	"bytes"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"slices"
)

type FlexFECControllerPolicy struct {
	SchemaVersion                  int    `json:"schemaVersion"`
	ControllerVersion              string `json:"controllerVersion"`
	EvaluationIntervalMilliseconds int    `json:"evaluationIntervalMilliseconds"`
	MinimumFinalizedPackets        uint64 `json:"minimumFinalizedPackets"`
	ReorderingGraceMilliseconds    int    `json:"reorderingGraceMilliseconds"`
	UpHoldWindows                  int    `json:"upHoldWindows"`
	DownCleanMilliseconds          int    `json:"downCleanMilliseconds"`
	TransitionHoldMilliseconds     int    `json:"transitionHoldMilliseconds"`
	FeedbackStaleMilliseconds      int    `json:"feedbackStaleMilliseconds"`
	LowLossBasisPoints             int    `json:"lowLossBasisPoints"`
	MediumLossBasisPoints          int    `json:"mediumLossBasisPoints"`
	HighLossBasisPoints            int    `json:"highLossBasisPoints"`
	RepairLossMinimumPackets       uint64 `json:"repairLossMinimumPackets"`
	RepairLossCapBasisPoints       int    `json:"repairLossCapBasisPoints"`
	BurstWindowMilliseconds        int    `json:"burstWindowMilliseconds"`
	MediumBurstPackets             int    `json:"mediumBurstPackets"`
	HighBurstPackets               int    `json:"highBurstPackets"`
	QueueTrendMilliseconds         int    `json:"queueTrendMilliseconds"`
}

type FlexFECControllerAssets struct {
	Policy              FlexFECControllerPolicy
	AllowedTiers        []FlexFECTier
	PolicySHA256        string
	RetainedTiersSHA256 string
}

type retainedFlexFECTierArtifact struct {
	SchemaVersion        int      `json:"schemaVersion"`
	EvidenceKind         string   `json:"evidenceKind"`
	BinarySHA256         string   `json:"binarySHA256"`
	SourceRevision       string   `json:"sourceRevision"`
	SourceRevisionSHA256 string   `json:"sourceRevisionSHA256"`
	Tiers                []string `json:"tiers"`
}

//go:embed testdata/flexfec_controller_policy.json
var embeddedFlexFECControllerPolicyJSON []byte

//go:embed testdata/flexfec_retained_tiers.json
var embeddedFlexFECRetainedTiersJSON []byte

var lowercaseSHA256Pattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

func loadFlexFECControllerAssets(explicitPolicy []byte) (FlexFECControllerAssets, error) {
	policyJSON := explicitPolicy
	if len(policyJSON) == 0 {
		policyJSON = embeddedFlexFECControllerPolicyJSON
	}
	policy, err := parseFlexFECControllerPolicy(policyJSON)
	if err != nil {
		return FlexFECControllerAssets{}, err
	}
	tiers, retainedSHA, err := parseRetainedFlexFECTiers(embeddedFlexFECRetainedTiersJSON)
	if err != nil {
		return FlexFECControllerAssets{}, err
	}
	return FlexFECControllerAssets{
		Policy: policy, AllowedTiers: append([]FlexFECTier(nil), tiers...),
		PolicySHA256: sha256Hex(policyJSON), RetainedTiersSHA256: retainedSHA,
	}, nil
}

func parseFlexFECControllerPolicy(data []byte) (FlexFECControllerPolicy, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var policy FlexFECControllerPolicy
	if err := decoder.Decode(&policy); err != nil {
		return FlexFECControllerPolicy{}, fmt.Errorf("decode FlexFEC controller policy: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return FlexFECControllerPolicy{}, fmt.Errorf("decode FlexFEC controller policy: trailing value")
		}
		return FlexFECControllerPolicy{}, fmt.Errorf("decode FlexFEC controller policy: %w", err)
	}
	if err := validateFlexFECControllerPolicy(policy); err != nil {
		return FlexFECControllerPolicy{}, fmt.Errorf("invalid FlexFEC controller policy: %w", err)
	}
	return policy, nil
}

func validateFlexFECControllerPolicy(policy FlexFECControllerPolicy) error {
	if policy.SchemaVersion != 1 || policy.ControllerVersion == "" {
		return fmt.Errorf("invalid schema or controller version")
	}
	interval := policy.EvaluationIntervalMilliseconds
	if interval <= 0 || policy.MinimumFinalizedPackets == 0 ||
		policy.ReorderingGraceMilliseconds <= 0 || policy.UpHoldWindows <= 0 ||
		policy.DownCleanMilliseconds < interval ||
		policy.TransitionHoldMilliseconds < interval ||
		policy.FeedbackStaleMilliseconds < interval ||
		policy.BurstWindowMilliseconds <= 0 || policy.MediumBurstPackets <= 0 ||
		policy.HighBurstPackets <= policy.MediumBurstPackets ||
		policy.QueueTrendMilliseconds <= 0 {
		return fmt.Errorf("invalid window, hold, burst, or queue configuration")
	}
	if policy.LowLossBasisPoints <= 0 ||
		policy.MediumLossBasisPoints < policy.LowLossBasisPoints ||
		policy.HighLossBasisPoints <= policy.MediumLossBasisPoints ||
		policy.HighLossBasisPoints > 10_000 {
		return fmt.Errorf("loss thresholds must be ordered within basis points")
	}
	if policy.RepairLossMinimumPackets == 0 ||
		policy.RepairLossCapBasisPoints <= 0 ||
		policy.RepairLossCapBasisPoints > 10_000 {
		return fmt.Errorf("repair-loss cap requires packets and basis points")
	}
	return nil
}

func parseRetainedFlexFECTiers(data []byte) ([]FlexFECTier, string, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var artifact retainedFlexFECTierArtifact
	if err := decoder.Decode(&artifact); err != nil {
		return nil, "", fmt.Errorf("decode retained FlexFEC tiers: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return nil, "", fmt.Errorf("decode retained FlexFEC tiers: trailing value")
		}
		return nil, "", fmt.Errorf("decode retained FlexFEC tiers: %w", err)
	}
	if artifact.SchemaVersion != 1 ||
		artifact.EvidenceKind != "flexfec-retained-static-tiers" ||
		artifact.SourceRevision == "" ||
		!lowercaseSHA256Pattern.MatchString(artifact.BinarySHA256) ||
		!lowercaseSHA256Pattern.MatchString(artifact.SourceRevisionSHA256) ||
		len(artifact.Tiers) == 0 {
		return nil, "", fmt.Errorf("invalid retained FlexFEC tier identity")
	}
	orderedNames := []string{"low", "medium", "high"}
	allowed := []FlexFECTier{FlexFECTierOff}
	lastIndex := -1
	for _, name := range artifact.Tiers {
		index := slices.Index(orderedNames, name)
		if index <= lastIndex {
			return nil, "", fmt.Errorf("retained FlexFEC tiers are invalid or unordered")
		}
		lastIndex = index
		switch name {
		case "low":
			allowed = append(allowed, FlexFECTierLow)
		case "medium":
			allowed = append(allowed, FlexFECTierMedium)
		case "high":
			allowed = append(allowed, FlexFECTierHigh)
		default:
			return nil, "", fmt.Errorf("unknown retained FlexFEC tier %q", name)
		}
	}
	return allowed, sha256Hex(data), nil
}

func sha256Hex(data []byte) string {
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:])
}
