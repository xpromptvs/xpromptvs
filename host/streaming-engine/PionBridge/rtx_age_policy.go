package main

import (
	"errors"
	"sync"
	"time"
)

var errInvalidRTXAgePolicyConfig = errors.New("invalid RTX age policy configuration")

type RTXAgeMode uint8

const (
	RTXAgeFixed RTXAgeMode = iota + 1
	RTXAgeRTT
)

type RTXAgePolicyConfig struct {
	Mode            RTXAgeMode
	Floor           time.Duration
	Cap             time.Duration
	MultiplierMilli uint32
}

type RTXAgePolicySnapshot struct {
	Mode                                  string `json:"mode"`
	FloorMilliseconds                     int64  `json:"floorMilliseconds"`
	CapMilliseconds                       int64  `json:"capMilliseconds"`
	MultiplierMilli                       uint32 `json:"multiplierMilli"`
	HasMediaRTT                           bool   `json:"hasMediaRTT"`
	CurrentMediaRTTMicroseconds           int64  `json:"currentMediaRTTMicroseconds"`
	EffectiveMaxAgeMilliseconds           int64  `json:"effectiveMaxAgeMilliseconds"`
	EffectiveThresholdSampleCount         uint64 `json:"effectiveThresholdSampleCount"`
	EffectiveThresholdMinimumMilliseconds int64  `json:"effectiveThresholdMinimumMilliseconds"`
	EffectiveThresholdMaximumMilliseconds int64  `json:"effectiveThresholdMaximumMilliseconds"`
}

type RTXAgePolicy struct {
	config   RTXAgePolicyConfig
	mediaRTT *mediaRTTEstimator

	mutex       sync.Mutex
	sampleCount uint64
	minimum     time.Duration
	maximum     time.Duration
}

func NewRTXAgePolicy(
	config RTXAgePolicyConfig,
	mediaRTT *mediaRTTEstimator,
) (*RTXAgePolicy, error) {
	if !validRTXAgeDuration(config.Floor) {
		return nil, errInvalidRTXAgePolicyConfig
	}
	switch config.Mode {
	case RTXAgeFixed:
		if (config.Cap != 0 && config.Cap != config.Floor) ||
			(config.MultiplierMilli != 0 && config.MultiplierMilli != 1_000) {
			return nil, errInvalidRTXAgePolicyConfig
		}
		config.Cap = config.Floor
		config.MultiplierMilli = 1_000
		mediaRTT = nil
	case RTXAgeRTT:
		if mediaRTT == nil || !validRTXAgeDuration(config.Cap) ||
			config.Cap < config.Floor || config.MultiplierMilli == 0 {
			return nil, errInvalidRTXAgePolicyConfig
		}
	default:
		return nil, errInvalidRTXAgePolicyConfig
	}
	return &RTXAgePolicy{config: config, mediaRTT: mediaRTT}, nil
}

func validRTXAgeDuration(value time.Duration) bool {
	return value >= time.Millisecond &&
		value <= time.Second &&
		value%time.Millisecond == 0
}

func (policy *RTXAgePolicy) EffectiveMaxAge() time.Duration {
	if policy == nil {
		return 0
	}
	effective, _, _ := policy.currentEffectiveMaxAge()
	policy.mutex.Lock()
	policy.sampleCount++
	if policy.minimum == 0 || effective < policy.minimum {
		policy.minimum = effective
	}
	if effective > policy.maximum {
		policy.maximum = effective
	}
	policy.mutex.Unlock()
	return effective
}

func (policy *RTXAgePolicy) NegotiatedRTXTime() time.Duration {
	if policy == nil {
		return 0
	}
	return policy.config.Cap
}

func (policy *RTXAgePolicy) Snapshot() RTXAgePolicySnapshot {
	if policy == nil {
		return RTXAgePolicySnapshot{}
	}
	effective, mediaRTT, hasMediaRTT := policy.currentEffectiveMaxAge()
	policy.mutex.Lock()
	sampleCount := policy.sampleCount
	minimum := policy.minimum
	maximum := policy.maximum
	policy.mutex.Unlock()
	mode := "fixed"
	if policy.config.Mode == RTXAgeRTT {
		mode = "rtt"
	}
	return RTXAgePolicySnapshot{
		Mode:                                  mode,
		FloorMilliseconds:                     policy.config.Floor.Milliseconds(),
		CapMilliseconds:                       policy.config.Cap.Milliseconds(),
		MultiplierMilli:                       policy.config.MultiplierMilli,
		HasMediaRTT:                           hasMediaRTT,
		CurrentMediaRTTMicroseconds:           mediaRTT.Microseconds(),
		EffectiveMaxAgeMilliseconds:           effective.Milliseconds(),
		EffectiveThresholdSampleCount:         sampleCount,
		EffectiveThresholdMinimumMilliseconds: minimum.Milliseconds(),
		EffectiveThresholdMaximumMilliseconds: maximum.Milliseconds(),
	}
}

func (policy *RTXAgePolicy) currentEffectiveMaxAge() (
	effective time.Duration,
	mediaRTT time.Duration,
	hasMediaRTT bool,
) {
	if policy.config.Mode == RTXAgeFixed {
		return policy.config.Floor, 0, false
	}
	mediaRTT, _, hasMediaRTT = policy.mediaRTT.Snapshot()
	if !hasMediaRTT {
		return policy.config.Floor, 0, false
	}
	scaled := scaleRTXAge(mediaRTT, policy.config.MultiplierMilli)
	if scaled < policy.config.Floor {
		scaled = policy.config.Floor
	}
	if scaled > policy.config.Cap {
		scaled = policy.config.Cap
	}
	return scaled, mediaRTT, true
}

func scaleRTXAge(value time.Duration, multiplierMilli uint32) time.Duration {
	nanoseconds := uint64(value)
	multiplier := uint64(multiplierMilli)
	whole := nanoseconds / 1_000
	remainder := nanoseconds % 1_000
	return time.Duration(whole*multiplier + remainder*multiplier/1_000)
}
