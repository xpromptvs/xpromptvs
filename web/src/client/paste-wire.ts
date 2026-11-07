import { bytesToBase64 } from "../lib/bridge-socket";

/// THE PASTE/DROP WIRE, the client's half (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §3):
/// the limits the host enforces, the message builders and the reply parser. The host's half is RdevCore
/// `PasteMessages`; `protocol/fixtures/paste-messages.json` holds both to the same bytes.

export const PASTE_CHUNK_BYTES = 16 * 1024;
/// 1 GiB a file and a delivery since 2026-10-02 (they were 50 and 100 MiB): a compressed folder is routinely
/// more, and asked, a big paste is SENT after a warning (`PASTE_WARN_BYTES`), not refused.
export const PASTE_FILE_MAX_BYTES = 1024 * 1024 * 1024;
export const PASTE_TEXT_MAX_BYTES = 4 * 1024 * 1024;
export const PASTE_TOTAL_MAX_BYTES = 1024 * 1024 * 1024;
/// A file over this is sent only once the person says so — the client's own rule, never the host's: the
/// warning names its size and that it may take a while.
export const PASTE_WARN_BYTES = 50 * 1024 * 1024;
export const PASTE_MAX_ITEMS = 32;
export const PASTE_NAME_MAX_BYTES = 255;
export const PASTE_TYPE_MAX_BYTES = 127;

export type PasteTo = { term: string } | { win: string };
export interface PastePoint { x: number; y: number }
export type PasteItemDecl =
  | { kind: "file"; name: string; type: string; size: number }
  | { kind: "text"; size: number };
export type PasteErrorReason = "too-large" | "malformed" | "not-driver" | "busy" | "no-target" | "disk" | "failed";
export type PasteReply =
  /// The delivery is OPEN on the Mac: its pieces may go (2026-10-02 — none is sent before it).
  | { t: "paste-accepted"; id: string }
  | { t: "paste-done"; id: string; how: "paste" | "drop" }
  | { t: "paste-error"; id: string; reason: PasteErrorReason };

const REASONS: readonly PasteErrorReason[] = ["too-large", "malformed", "not-driver", "busy", "no-target", "disk", "failed"];
const utf8 = new TextEncoder();
const byteLength = (s: string) => utf8.encode(s).length;

/// A name the host accepts: at most 255 UTF-8 bytes, cut on a CHARACTER (code point) and keeping a short
/// extension. The host maps it again for the disk (§6); this only keeps the message legal.
export function fitName(name: string): string {
  if (byteLength(name) <= PASTE_NAME_MAX_BYTES) return name;
  const dot = name.lastIndexOf(".");
  const ext = dot > 0 && name.length - dot <= 9 ? name.slice(dot) : "";
  const chars = Array.from(ext ? name.slice(0, dot) : name).slice(0, PASTE_NAME_MAX_BYTES);
  const room = PASTE_NAME_MAX_BYTES - byteLength(ext);
  while (chars.length && byteLength(chars.join("")) > room) chars.pop();
  return chars.join("") + ext;
}

export function fitType(type: string): string {
  return byteLength(type) <= PASTE_TYPE_MAX_BYTES ? type : "";
}

/// Over a cap the host enforces — refused here, before a byte is sent (the host refuses it anyway).
export function overCaps(items: readonly PasteItemDecl[]): boolean {
  if (items.length === 0 || items.length > PASTE_MAX_ITEMS) return true;
  let total = 0;
  for (const it of items) {
    if (it.size > (it.kind === "text" ? PASTE_TEXT_MAX_BYTES : PASTE_FILE_MAX_BYTES)) return true;
    total += it.size;
  }
  return total > PASTE_TOTAL_MAX_BYTES;
}

export function pasteBegin(id: string, to: PasteTo, items: readonly PasteItemDecl[], at?: PastePoint): Record<string, unknown> {
  const msg: Record<string, unknown> = {
    t: "paste-begin", id, to,
    items: items.map((i) => i.kind === "file"
      ? { kind: "file", name: i.name, type: i.type, size: i.size }
      : { kind: "text", size: i.size }),
  };
  if (at) msg.at = { x: at.x, y: at.y };
  return msg;
}

export function pasteData(id: string, item: number, seq: number, bytes: Uint8Array): Record<string, unknown> {
  return { t: "paste-data", id, item, seq, data: bytesToBase64(bytes) };
}
export const pasteEnd = (id: string) => ({ t: "paste-end", id });
export const pasteCancel = (id: string) => ({ t: "paste-cancel", id });

export function parsePasteReply(m: unknown): PasteReply | null {
  if (typeof m !== "object" || m === null) return null;
  const o = m as Record<string, unknown>;
  if (typeof o.id !== "string") return null;
  if (o.t === "paste-accepted") return { t: "paste-accepted", id: o.id };
  if (o.t === "paste-done" && (o.how === "paste" || o.how === "drop")) return { t: "paste-done", id: o.id, how: o.how };
  if (o.t === "paste-error" && REASONS.includes(o.reason as PasteErrorReason)) {
    return { t: "paste-error", id: o.id, reason: o.reason as PasteErrorReason };
  }
  return null;
}
