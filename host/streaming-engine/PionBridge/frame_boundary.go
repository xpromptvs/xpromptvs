package main

import "github.com/pion/rtp"

// frameBoundary is what the FEC needs to know about one outgoing RTP packet: where it sits in its
// frame, and — only when it STARTS one — what kind of frame that is.
//
// IT EXISTS BECAUSE THE DEPENDENCY DESCRIPTOR IS NOT UNIVERSAL. Browsers negotiate it for AV1 and
// VP9 only, so an H.264 or H.265 session carries none and rdev attaches none
// (emitsDependencyDescriptor is per profile). Reading these four facts straight out of the
// descriptor therefore worked for exactly one codec, and FlexFEC was structurally unable to protect
// the other two.
//
// KEYFRAME AND TEMPORALID ARE MEANINGFUL ONLY WHEN `first` IS TRUE, and that is a property of the
// wire rather than a convenience. An H.264 FU-A continuation carries no NAL type of its own — the
// real type is in the FU header of the FIRST fragment — so a source that re-derived `keyframe` per
// packet would report false for every continuation packet of a keyframe. Any check that compared it
// against the frame in progress would then reject that whole frame. The continuation branch of
// `accept` must never compare them; see the comment there.
type frameBoundary struct {
	first      bool
	last       bool
	keyframe   bool
	temporalID uint8

	// The descriptor this boundary came from, retained when there was one and nil otherwise.
	//
	// It is kept so the CONTINUATION consistency check can compare TemplateID/TemporalID exactly as
	// it does today whenever both packets carried a descriptor — which is what keeps AV1, RdevViewer
	// and `llv capture-view` byte-for-byte unchanged by this increment. The NAL source has no
	// equivalent and must not pretend to: it asserts timestamp and sequence consecutiveness, which is
	// everything it can honestly know.
	descriptor *ParsedDependencyDescriptor
}

// boundaryFromDescriptor is today's arithmetic, moved and not altered.
func boundaryFromDescriptor(data []byte) (frameBoundary, error) {
	descriptor, err := parseOutboundDependencyDescriptor(data)
	if err != nil {
		return frameBoundary{}, err
	}
	return frameBoundary{
		first:      descriptor.FirstPacket,
		last:       descriptor.LastPacket,
		keyframe:   descriptor.TemplateID == 0,
		temporalID: descriptor.TemporalID,
		descriptor: &descriptor,
	}, nil
}

// boundaryFromRTP derives a boundary with no dependency descriptor, from the RTP header and payload.
//
// `last` is the MARKER BIT, which is already established as authoritative: today's descriptor path
// cross-checks the marker against the descriptor and errors when they disagree.
//
// `first` is "no frame is in progress", and it is EXACT here for one reason worth stating — this
// interceptor is on the SEND path, where packets arrive complete and in order by construction. There
// is no lost first packet to misread. The identical derivation on a receive path would be wrong.
//
// `temporalID` is 0 because rdev runs AV1ScalabilityL1T1 (rdev_abi.go): one temporal layer, so
// selectFlexFECFrame's tier test is inert and every tier protects every frame identically.
//
// `keyframe` is asked ONLY when this packet starts a frame. A continuation cannot answer it — an
// FU-A continuation carries no NAL type of its own — so it is left false and `accept` must not
// compare it against the frame in progress.
func boundaryFromRTP(
	header *rtp.Header,
	payload []byte,
	profile videoCodecProfile,
	frameInProgress bool,
) frameBoundary {
	first := !frameInProgress
	boundary := frameBoundary{first: first, last: header.Marker}
	if first {
		boundary.keyframe = profile.keyframeFromPayload(payload)
	}
	return boundary
}
