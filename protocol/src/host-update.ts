/** One release identity across native, web, and publication. Unknown old hosts stay unknown. */
export type ReleaseChannel = 'staging' | 'public';
export interface ReleaseIdentity { channel: ReleaseChannel; build: number; version: string; revision: string; published: boolean }
export function positiveBuild(v: unknown): v is number { return typeof v === 'number' && Number.isSafeInteger(v) && v > 0; }
export function parseReleaseIdentity(v: unknown): ReleaseIdentity | null {
  if (!v || typeof v !== 'object') return null;
  const r = v as Record<string, unknown>;
  if ((r.channel !== 'staging' && r.channel !== 'public') || !positiveBuild(r.build) || typeof r.published !== 'boolean' ||
      typeof r.version !== 'string' || !r.version.length || r.version.length > 64 || typeof r.revision !== 'string' || !r.revision.length || r.revision.length > 128) return null;
  return { channel:r.channel, build:r.build, version:r.version, revision:r.revision, published:r.published };
}
export type ReleaseComparison = 'older' | 'equal' | 'newer' | 'unknown' | 'channel-mismatch';
export function compareReleases(host: unknown, client: unknown): ReleaseComparison {
  const h = parseReleaseIdentity(host), c = parseReleaseIdentity(client);
  if (!h || !c) return 'unknown';
  if (h.channel !== c.channel) return 'channel-mismatch';
  return h.build < c.build ? 'older' : h.build > c.build ? 'newer' : 'equal';
}
export interface HostUpdateRequest { t:'host-update-request'; requestId:string; minimumBuild:number }
export function parseHostUpdateRequest(v: unknown): HostUpdateRequest | null {
  if (!v || typeof v !== 'object') return null;
  const r = v as Record<string,unknown>;
  if (Object.keys(r).some(k => !['t','requestId','minimumBuild'].includes(k)) || r.t !== 'host-update-request' ||
      typeof r.requestId !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(r.requestId) || !positiveBuild(r.minimumBuild)) return null;
  return {t:r.t, requestId:r.requestId, minimumBuild:r.minimumBuild};
}
export interface HostInfo { t:'host-info'; release:ReleaseIdentity|null; update:{supported:boolean;allowed:boolean;eligible:boolean;availableBuild:number|null} }
export type HostUpdatePhase = 'checking'|'downloading'|'verifying'|'restarting'|'succeeded'|'failed'|'cancelled'|'rolled-back';
export interface HostUpdateStatus { t:'host-update-status';requestId:string;phase:HostUpdatePhase;targetBuild?:number;error?:string }
export interface ReleaseManifest extends ReleaseIdentity { artifactURL:string;size:number;sha256:string }
