/// Should this window's <video> be re-bound to `next`?
///
/// THE OLD TEST ASKED THE WRONG QUESTION. `sync` compared MediaStream OBJECTS — "is this a different
/// stream?" — when what matters is "is the element rendering the current TRACK?". Those coincide on
/// Chrome, which delivers a replacement track on a fresh MediaStream object, and diverge on WebKit,
/// which appears to reuse the object. Measured: a codec switch freezes the picture on an AV1-capable
/// iPhone and not on desktop Chrome, with identical JavaScript.
///
/// The replacement track carries the SAME MSID — the source id — because that is how rdev keys
/// `streamsBySource`, so the object comparison cannot see it. The track id can.
///
/// NOT REBINDING IS AS LOAD-BEARING AS REBINDING. `sync` runs on every view-set; a predicate that
/// returned true in the steady state would rewrite `srcObject` continuously, which is visible
/// flicker — a cure worse than the freeze it replaces.
export function shouldRebindVideo(
  current: MediaStream | null,
  boundTrack: MediaStreamTrack | undefined,
  next: MediaStream,
  boundIdentity?: string,
  nextIdentity?: string,
): boolean {
  if (current !== next) return true;
  const track = next.getVideoTracks()[0];
  // No track yet: nothing to compare and nothing to render, so leave the binding alone rather than
  // churning it every view-set until one arrives.
  if (track === undefined) return false;
  // BY OBJECT IDENTITY, NOT BY id. This compared ids until 2026-08-26, which cannot see rdev's own
  // replacement: `wireVideoTrack("video-"+sourceID, ...)` names every track for a source
  // DETERMINISTICALLY, so a codec change hands over a fresh track under the SAME id and the SAME
  // MSID. On WebKit, which reuses the MediaStream object, both comparisons then read "unchanged" and
  // the element renders a dead track forever — frozen on the last frame of the previous codec while
  // getStats happily reports frames decoded.
  //
  // A replacement track is always a new OBJECT, whatever it is called, so identity is the question
  // that actually matches the thing being decided: is this element rendering the track it holds?
  // WebKit can reuse the receiver track itself after driver reclamation.
  // The negotiated MSID track identity still changes for the new host slot.
  return track !== boundTrack || (nextIdentity !== undefined && nextIdentity !== boundIdentity);
}

export function bindVideo(el: HTMLVideoElement, stream: MediaStream): void {
  if (el.srcObject === stream) el.srcObject = null;
  el.srcObject = stream;
  void el.play().catch(() => { /* autoplay may require a user gesture */ });
}

/// What the receiver knows about one element in the last stats window.
export interface ElementHealth {
  /// Frames the element PRESENTED, counted by requestVideoFrameCallback. Not `framesDecoded`, which
  /// is the decoder's, and not `currentTime`, which on a MediaStream is a wall clock.
  presented: number;
  /// Frames the decoder produced in the same window. A source nobody is touching produces none —
  /// rdev's capture is content-driven — and that is NOT a freeze.
  decodedDelta: number;
  trackLive: boolean;
  paused: boolean;
  hidden: boolean;
}

/// How many consecutive frozen windows before re-attaching. TWO, not one: a single window can be a
/// scheduling artefact, and `srcObject` churn is the documented way to make this worse — an
/// always-true predicate rewrites the binding continuously and flickers.
export const FROZEN_WINDOWS_BEFORE_REBIND = 2;

/// Decide whether an element that is DECODING but not PAINTING should be re-attached, and carry the
/// frozen-window streak forward.
///
/// WHY THIS EXISTS. A `<video>` can decode every frame and present none: measured on a real session as
/// `frames=298/298 dropped=0 freeze=0 lost=0 pli=0 jbuf=1.1ms` with ZERO frames presented, after the
/// playout-delay floor was raised to 100ms and returned to Auto. Every counter the receiver reports
/// described a healthy stream, because they all describe the DECODER. Re-attaching `srcObject` is the
/// same recovery `shouldRebindVideo` performs for a replaced track; this reaches the case where the
/// track is fine and the element has stopped rendering it.
///
/// THE GUARDS ARE THE DESIGN. Freezing is indistinguishable from idleness unless the decoder is known
/// to be advancing, and from user intent unless paused/hidden are excluded — and rebinding a dead
/// track cannot help, since that needs a new track rather than a re-attach.
export function frozenElementNeedsRebind(
  h: ElementHealth,
  frozenWindows: number,
): { rebind: boolean; frozenWindows: number } {
  const frozen = h.presented === 0 && h.decodedDelta > 0
    && h.trackLive && !h.paused && !h.hidden;
  if (!frozen) return { rebind: false, frozenWindows: 0 };
  const streak = frozenWindows + 1;
  // Reset on rebind: the next freeze must earn its own two windows, so a rebind that does not help
  // cannot turn into a rebind every window.
  return streak >= FROZEN_WINDOWS_BEFORE_REBIND
    ? { rebind: true, frozenWindows: 0 }
    : { rebind: false, frozenWindows: streak };
}
