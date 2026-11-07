package main

import "sync/atomic"

// flexFECOverrideSetBit distinguishes "no override" from "override, zero percent" in one word.
// Both facts have to arrive in a single atomic load: this is read on the RTP write path, and a
// reader that took them separately could observe a half-applied change in the middle of a frame —
// protecting some of its packets and not others.
const flexFECOverrideSetBit uint32 = 1 << 31

// maximumFlexFECOverrideBasisPoints is 50% overhead. Above this the repair stream rivals the media
// stream, and the egress budget starts suppressing it, so the number requested stops being the
// number delivered.
const maximumFlexFECOverrideBasisPoints uint32 = 5000

// FlexFECOverrideStore holds an operator-forced FEC overhead, in basis points of media.
//
// IT IS DELIBERATELY SEPARATE FROM FlexFECTierStore. The tier is what the adaptive controller
// decided; the override is what an operator forced. Folding them together would make the stats
// report one as the other, and "the controller wanted Medium" and "somebody pinned 30%" are
// different facts about a session.
type FlexFECOverrideStore struct{ value atomic.Uint32 }

func NewFlexFECOverrideStore() *FlexFECOverrideStore { return &FlexFECOverrideStore{} }

// Set forces an overhead. A value above the maximum is clamped rather than refused: this is the
// last line before the RTP path, and the callers that can refuse (Session.SetRecoveryOverride, the
// ABI) already have.
func (store *FlexFECOverrideStore) Set(bp uint32) {
	if store == nil {
		return
	}
	if bp > maximumFlexFECOverrideBasisPoints {
		bp = maximumFlexFECOverrideBasisPoints
	}
	store.value.Store(flexFECOverrideSetBit | bp)
}

// Clear returns the session to adaptive control.
func (store *FlexFECOverrideStore) Clear() {
	if store == nil {
		return
	}
	store.value.Store(0)
}

func (store *FlexFECOverrideStore) Load() (uint32, bool) {
	if store == nil {
		return 0, false
	}
	raw := store.value.Load()
	if raw&flexFECOverrideSetBit == 0 {
		return 0, false
	}
	return raw &^ flexFECOverrideSetBit, true
}

// flexFECShape is the protection decision for ONE frame, captured once when the frame's first
// packet arrives and carried until its repairs are emitted.
//
// CAPTURING IT PER FRAME IS THE POINT, not an optimisation: an override that changed mid-frame
// would otherwise protect some of that frame's packets under one ratio and generate its repairs
// under another, and the FEC group would not describe the packets it covers.
type flexFECShape struct {
	tier       FlexFECTier
	overrideBp uint32
	overridden bool
}

// silent reports that this shape protects nothing at all.
func (shape flexFECShape) silent() bool {
	if shape.overridden {
		return shape.overrideBp == 0
	}
	return shape.tier == FlexFECTierOff
}

// currentFlexFECShape reads both stores as one decision.
func currentFlexFECShape(tier *FlexFECTierStore, override *FlexFECOverrideStore) flexFECShape {
	bp, set := override.Load()
	return flexFECShape{tier: tier.Load(), overrideBp: bp, overridden: set}
}
