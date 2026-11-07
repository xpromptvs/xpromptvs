/// Pure parse + view-model for the window-preview tiles. `parseSourceThumb` narrows the host's
/// `source-thumb` message; `galleryTiles` maps sources + the subscribed set + focus + a per-source
/// thumbnail map to render-ready tiles.
///
/// The standalone gallery MODAL is gone (2026-07-28) — the command palette renders these tiles now, so
/// this file is pure model with no DOM controller.
import { type Source, type SourceRow, sourceStateLabel } from "./source-picker";

/// A decoded `source-thumb`: either a ready data URL or an `unavailable` marker.
export interface SourceThumb { id: string; dataUrl?: string; unavailable?: boolean }

/// What we know about one source's snapshot. `dataUrl` = captured; `unavailable` = no pixels / failed.
export type ThumbEntry = { dataUrl: string } | { unavailable: true };

/// The render state of a tile's image area.
export type ThumbState =
  | { kind: "loading" }                        // running source, capture in flight
  | { kind: "image"; dataUrl: string }         // captured
  | { kind: "placeholder" };                   // no capture coming (not running) or reported unavailable

export interface GalleryTile {
  id: string; kind: string; name: string; running: boolean;
  subscribed: boolean; focused: boolean; stateLabel: string | null; thumb: ThumbState;
}

/// Narrow a decoded control-channel JSON message to a SourceThumb, or null. A jpeg message is turned into a
/// ready-to-use `data:` URL here so the caller just stores it.
export function parseSourceThumb(msg: unknown): SourceThumb | null {
  if (typeof msg !== "object" || msg === null) return null;
  const m = msg as Record<string, unknown>;
  if (m.t !== "source-thumb" || typeof m.id !== "string") return null;
  if (m.unavailable === true) return { id: m.id, unavailable: true };
  if (m.fmt !== "jpeg" || typeof m.data !== "string") return null;
  return { id: m.id, dataUrl: `data:image/jpeg;base64,${m.data}` };
}

function thumbState(s: Source, e: ThumbEntry | undefined): ThumbState {
  if (e && "dataUrl" in e) return { kind: "image", dataUrl: e.dataUrl };
  if (e && "unavailable" in e) return { kind: "placeholder" };
  if (!s.running) return { kind: "placeholder" };   // shut-down sim / minimized window: no capture is coming
  return { kind: "loading" };
}

/// Map sources + the subscribed set + focus + the thumbnail map to gallery tiles.
export function galleryTiles(
  sources: Source[], subscribed: string[], focused: string | null, thumbs: Map<string, ThumbEntry>,
): GalleryTile[] {
  const set = new Set(subscribed);
  return sources.map((s) => {
    const row: SourceRow = {
      id: s.id, kind: s.kind, name: s.name, running: s.running, inputCapable: s.inputCapable, current: set.has(s.id),
      simState: s.simState,
    };
    return {
      id: s.id, kind: s.kind, name: s.name, running: s.running,
      subscribed: set.has(s.id), focused: focused === s.id,
      stateLabel: sourceStateLabel(row), thumb: thumbState(s, thumbs.get(s.id)),
    };
  });
}
