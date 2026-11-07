import { describe, it, expect } from 'vitest';
import { remoteTrackIdentity } from '../src/lib/remote-track-identity';
const sdp = 'v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 45\r\na=mid:1\r\na=msid:win:1 video-0-win:1\r\nm=video 9 UDP/TLS/RTP/SAVPF 45\r\na=mid:2\r\na=msid:win:2 video-1-win:2\r\n';
describe('negotiated receiver identity', () => {
  it('uses the negotiated MSID track identity rather than WebKit’s generated track UUID', () => {
    expect(remoteTrackIdentity(sdp, '1', 'win:1')).toBe('video-0-win:1');
  });
  it('cannot bind another source or transceiver', () => {
    expect(remoteTrackIdentity(sdp, '2', 'win:1')).toBeUndefined();
    expect(remoteTrackIdentity(sdp, null, 'win:1')).toBeUndefined();
  });
  it('changes when the sender replaces the track', () => {
    expect(remoteTrackIdentity(sdp.replace('video-0-win:1', 'video-9-win:1'), '1', 'win:1')).toBe('video-9-win:1');
  });
  it('refuses ambiguous identities', () => {
    expect(remoteTrackIdentity(sdp.replace('a=mid:1', 'a=msid:win:1 another\r\na=mid:1'), '1', 'win:1')).toBeUndefined();
  });
});
