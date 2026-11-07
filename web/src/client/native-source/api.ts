import type { NativeSourceManifest } from './manifest';
import type { SourceWindowKey } from './types';
export interface NativeSourceInfo {
  supported: boolean; generation: number; revision: number; visible: boolean; keyWindow: boolean;
}
export type NativeSourceEvent =
  | { type: 'reset'; generation: number; reason: string; ended?: boolean }
  | { type: 'owner-visibility'; generation: number; visible: boolean; keyWindow: boolean }
  | { type: 'created' | 'ready'; key: SourceWindowKey }
  | { type: 'gone'; key: SourceWindowKey; reason: string }
  | { type: 'key'; key: SourceWindowKey; keyWindow: boolean }
  | { type: 'visibility'; key: SourceWindowKey; visible: boolean; minimized: boolean; keyWindow: boolean }
  | { type: 'action'; key: SourceWindowKey; name: string; land?: boolean; on?: boolean; width?: number; height?: number; x?: number; y?: number };
export interface NativeSourceWindowAPI {
  nativeSourceWindowsInfo(): Promise<NativeSourceInfo>;
  syncSourceWindows(manifest: NativeSourceManifest): Promise<NativeSourceInfo>;
  prepareSourceWindow(source: string, generation: number): Promise<{ticket:string;url:string;key:SourceWindowKey}>;
  resetSourceWindows(generation: number): Promise<NativeSourceInfo>;
  sourceWindowCommand(key: SourceWindowKey, command: 'activate' | 'restore' | 'close' | 'fit' | 'fullscreen' | 'minimize' | 'confirmSize', value?: unknown): Promise<unknown>;
  onSourceWindowEvent(callback: (event: NativeSourceEvent) => void): () => void;
}

export function nativeSourceWindowAPI(value: Partial<NativeSourceWindowAPI> | undefined): NativeSourceWindowAPI | undefined {
  if(value && ['nativeSourceWindowsInfo','syncSourceWindows','prepareSourceWindow','resetSourceWindows','sourceWindowCommand','onSourceWindowEvent']
    .every(name=>typeof value[name as keyof NativeSourceWindowAPI]==='function'))return value as NativeSourceWindowAPI;
}
