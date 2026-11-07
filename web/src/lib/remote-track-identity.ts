/** WebKit gives receiver.track a fresh UUID; the sender's track ID lives in SDP.
 * Match the event's transceiver AND stream, then bind that identity to the actual
 * receiver object. A source name alone cannot distinguish a replacement. */
export function remoteTrackIdentity(sdp: string, mid: string | null, source: string): string | undefined {
  if (mid === null) return;
  const ids: string[] = [];
  for (const section of sdp.split(/(?=^m=)/m)) {
    const lines = section.split(/\r?\n/);
    if (!lines.includes(`a=mid:${mid}`)) continue;
    for (const line of lines) {
      const match = /^a=msid:(\S+) (\S+)$/.exec(line);
      if (match?.[1] === source) ids.push(match[2]!);
    }
  }
  return ids.length === 1 ? ids[0] : undefined;
}
