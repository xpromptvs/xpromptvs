import type { Source, ViewSetMsg } from '../source-picker';
export interface NativeSourceMember {
  source: string;
  kind: 'window' | 'display' | 'simulator';
  title: string;
  minimized: boolean;
  width?: number;
  height?: number;
  audioStatus?: {state:"muted"|"yielded";title:string};
}
export interface NativeSourceManifest {
  generation: number;
  revision: number;
  driving: boolean;
  focused: string | null;
  theme: 'dark' | 'light';
  sources: NativeSourceMember[];
}
function kind(source: string): NativeSourceMember['kind'] | undefined {
  if (/^sim:.+/.test(source)) return 'simulator';
  const match = /^(win|dsp):(\d+)$/.exec(source);
  if (!match || Number(match[2]) > 0xffffffff) return undefined;
  return match[1] === 'win' ? 'window' : 'display';
}
/** Full host membership, before windowViews omits minimized windows. Never admit application capture. */
export function nativeSourceManifest(generation: number, revision: number, state: ViewSetMsg,
  catalog: readonly Source[], driving: boolean, theme: 'dark' | 'light', sizes: ReadonlyMap<string, {w:number;h:number}>, audio:ReadonlyMap<string,NativeSourceMember["audioStatus"]> = new Map()): NativeSourceManifest {
  const sources: NativeSourceMember[] = [];
  for (const window of state.windows) {
    const sourceKind = kind(window.source); if (!sourceKind) continue;
    const source = catalog.find(s => s.id === window.source), size = sizes.get(window.source);
    const member: NativeSourceMember = { source: window.source, kind: sourceKind,
      title: window.name ?? source?.name ?? window.source, minimized: window.minimized };
    const width = size?.w ?? source?.w, height = size?.h ?? source?.h;
    if (width !== undefined && Number.isFinite(width) && width > 0 && width <= 32768) member.width = width;
    if (height !== undefined && Number.isFinite(height) && height > 0 && height <= 32768) member.height = height;
    const status=audio.get(window.source);if(status)member.audioStatus=status;
    sources.push(member);
  }
  return { generation, revision, driving, theme, sources,
    focused: sources.some(s => s.source === state.focused && !s.minimized) ? state.focused : null };
}
