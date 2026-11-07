/// The bridge between what WebRTC negotiated and what WebCodecs can decode.
///
/// rdev negotiates AV1 (pt 45), H.265 (pt 108) and H.264 (pt 102). The profile table in
/// `PionBridge/video_codec_profile.go` is the single place a codec is described on the host side, so
/// this READS the negotiated description rather than restating it.

/// ANNEX-B, NOT LENGTH-PREFIXED. The RTP depacketizer hands H.264/H.265 to the encoded transform with
/// start codes, so `VideoDecoder.configure()` takes NO `description` — and H.265 must be `hev1.*`
/// (parameter sets in band), never `hvc1.*`, which would describe a length-prefixed stream.
export function webCodecsStringFor(mimeType: string, fmtp?: string): string | null {
  const m = mimeType.toLowerCase().replace(/^video\//, "");
  if (m === "av1" || m === "av01") return "av01.0.04M.08";
  if (m === "h265" || m === "hevc") return "hev1.1.6.L93.B0";
  if (m === "h264") {
    const id = /profile-level-id=([0-9a-fA-F]{6})/.exec(fmtp ?? "")?.[1];
    return `avc1.${(id ?? "42e01f").toLowerCase()}`;
  }
  return null;
}

/// payloadType -> WebCodecs codec string, read out of a session description. Only decodable media
/// codecs appear, so rtx/red/ulpfec/flexfec payload types are absent by construction — a frame
/// carrying one of those never reaches the decoder anyway.
export function parsePayloadTypeMap(sdp: string): Map<number, string> {
  const lines = sdp.split(/\r?\n/);
  const fmtps = new Map<number, string>();
  for (const line of lines) {
    const f = /^a=fmtp:(\d+)\s+(.*)$/.exec(line);
    if (f) fmtps.set(Number(f[1]), f[2]!);
  }
  const out = new Map<number, string>();
  for (const line of lines) {
    const r = /^a=rtpmap:(\d+)\s+([^/]+)\//.exec(line);
    if (!r) continue;
    const pt = Number(r[1]);
    const codec = webCodecsStringFor(r[2]!, fmtps.get(pt));
    if (codec) out.set(pt, codec);
  }
  return out;
}
