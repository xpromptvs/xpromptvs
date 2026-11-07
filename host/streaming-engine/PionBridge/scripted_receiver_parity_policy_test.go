package main

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

const scriptedParityKeyframePacketCount = 15

type scriptedParityPolicy struct {
	SchemaVersion int                  `json:"schemaVersion"`
	Cases         []scriptedParityCase `json:"cases"`
}

type scriptedParityCase struct {
	Name                    string `json:"name"`
	Profile                 string `json:"profile"`
	Seed                    int64  `json:"seed"`
	MeasuredFrames          int    `json:"measuredFrames"`
	ScriptedKeyframeOffsets []int  `json:"scriptedKeyframeOffsets"`
}

func TestScriptedReceiverParityKeyframesUseLossFreeSourceCoordinates(t *testing.T) {
	policyData, err := os.ReadFile("testdata/scripted_receiver_parity_policy.json")
	if err != nil {
		t.Fatal(err)
	}
	var policy scriptedParityPolicy
	if err := json.Unmarshal(policyData, &policy); err != nil {
		t.Fatal(err)
	}
	catalog, err := loadRecoveryMatrixCatalog(recoveryMatrixCatalogJSON)
	if err != nil {
		t.Fatal(err)
	}
	profiles := make(map[string]RecoveryMatrixProfile, len(catalog.Profiles))
	for _, profile := range catalog.Profiles {
		profiles[profile.Name] = profile
	}
	for _, parityCase := range policy.Cases {
		profile, ok := profiles[parityCase.Profile]
		if !ok {
			t.Errorf("%s references missing profile %s", parityCase.Name, parityCase.Profile)
			continue
		}
		if profile.MediaLossBasisPoints == 0 {
			continue
		}
		if last := parityCase.ScriptedKeyframeOffsets[len(parityCase.ScriptedKeyframeOffsets)-1]; last != parityCase.MeasuredFrames-1 {
			t.Errorf("%s final keyframe offset = %d, want %d",
				parityCase.Name, last, parityCase.MeasuredFrames-1)
		}
		profile.Seed = new(int64)
		*profile.Seed = parityCase.Seed
		controller := newRecoveryImpairmentController(profile)
		stride := 8
		expected := scriptedParityLossFreeSchedule(
			t, controller, parityCase.MeasuredFrames, stride,
		)
		if !reflect.DeepEqual(parityCase.ScriptedKeyframeOffsets, expected) {
			t.Errorf("%s scripted offsets = %v, want %v",
				parityCase.Name, parityCase.ScriptedKeyframeOffsets, expected)
		}
		var unsafe []int
		var safe []int
		for offset := 0; offset < parityCase.MeasuredFrames; offset++ {
			if scriptedParityKeyframeCoordinateIsLossFree(controller, offset) {
				safe = append(safe, offset)
			}
		}
		for _, offset := range parityCase.ScriptedKeyframeOffsets {
			if !scriptedParityKeyframeCoordinateIsLossFree(controller, offset) {
				unsafe = append(unsafe, offset)
			}
		}
		if len(unsafe) > 0 {
			t.Errorf("%s has lossy keyframe offsets %v; loss-free offsets are %v",
				parityCase.Name, unsafe, safe)
		}
	}
}

func scriptedParityLossFreeSchedule(
	t *testing.T,
	controller *RecoveryImpairmentController,
	measuredFrames int,
	stride int,
) []int {
	t.Helper()
	last := measuredFrames - 1
	var offsets []int
	for target := stride; target < last; target += stride {
		windowEnd := min(target+stride, last)
		selected := -1
		for candidate := target; candidate < windowEnd; candidate++ {
			if scriptedParityKeyframeCoordinateIsLossFree(controller, candidate) {
				selected = candidate
				break
			}
		}
		if selected < 0 {
			t.Fatalf("no loss-free scripted keyframe in offsets %d..<%d",
				target, windowEnd)
		}
		offsets = append(offsets, selected)
	}
	if !scriptedParityKeyframeCoordinateIsLossFree(controller, last) {
		t.Fatalf("terminal offset %d is not loss-free", last)
	}
	if len(offsets) == 0 || offsets[len(offsets)-1] != last {
		offsets = append(offsets, last)
	}
	return offsets
}

func scriptedParityKeyframeCoordinateIsLossFree(
	controller *RecoveryImpairmentController,
	offset int,
) bool {
	for packetIndex := 1; packetIndex <= scriptedParityKeyframePacketCount; packetIndex++ {
		classification := recoveryDatagramClassification{
			Endpoint:                 matrixHost,
			Class:                    matrixPacketOriginal,
			OriginalFrameOrdinal:     uint64(offset + 1),
			OriginalFramePacketIndex: uint64(packetIndex),
		}
		if controller.randomIntnLocked(classification, "loss", 10_000) <
			controller.profile.MediaLossBasisPoints {
			return false
		}
	}
	return true
}
