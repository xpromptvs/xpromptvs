/**
 * The negotiated inbound video codec's mimeType (e.g. "video/AV1", "video/H265"), or null when no
 * inbound video track has arrived yet.
 *
 * Surfaced on `window.__rdev` only — deliberately NOT in the footer, which was cut to three cells on
 * 2026-07-28. This exists so the AV1 browser gate and the AV1-vs-H.265 measurement have something to
 * read that is not chrome://webrtc-internals.
 *
 * With several sources subscribed there are several inbound-rtp entries, but codec selection is
 * per-CONNECTION (the host caches it and pins later tracks to it), so the first video entry is
 * representative.
 */
export function inboundVideoCodec(report: RTCStatsReport): string | null {
  let mime: string | null = null;
  report.forEach((r) => {
    const s = r as { type?: string; kind?: string; codecId?: string };
    if (mime || s.type !== "inbound-rtp" || s.kind !== "video" || !s.codecId) return;
    const c = report.get(s.codecId) as { mimeType?: string } | undefined;
    if (c?.mimeType) mime = c.mimeType;
  });
  return mime;
}
