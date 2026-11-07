package main

import (
	"sync/atomic"
	"time"
)

const (
	ntpUnixEpochOffsetSeconds = 2_208_988_800
	maximumObservedMediaRTT   = 10 * time.Second
)

type mediaRTTEstimator struct {
	latestNanoseconds atomic.Int64
	observations      atomic.Uint64
}

func (estimator *mediaRTTEstimator) Observe(sample time.Duration) bool {
	if estimator == nil || sample <= 0 || sample > maximumObservedMediaRTT {
		return false
	}
	estimator.latestNanoseconds.Store(int64(sample))
	estimator.observations.Add(1)
	return true
}

func (estimator *mediaRTTEstimator) Snapshot() (time.Duration, uint64, bool) {
	if estimator == nil {
		return 0, 0, false
	}
	observations := estimator.observations.Load()
	latest := time.Duration(estimator.latestNanoseconds.Load())
	return latest, observations, observations != 0 && latest > 0
}

func compactNTP(value time.Time) uint32 {
	seconds := uint64(value.Unix() + ntpUnixEpochOffsetSeconds)
	fraction := uint64(value.Nanosecond()) << 32 / uint64(time.Second)
	return uint32(seconds<<16 | fraction>>16)
}

func compactNTPTicksToDuration(ticks uint32) time.Duration {
	return time.Duration(uint64(ticks) * uint64(time.Second) / 65_536)
}
