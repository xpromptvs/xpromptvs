import { fitName, fitType } from "./paste-wire";
import type { PasteSource } from "./paste-upload";

/// WHERE A PASTE'S CONTENT COMES FROM (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §2.3, §2.5):
/// the async clipboard, the system picker, and a paste event's or a drop's `DataTransfer`.

export const IMAGE_TYPES: readonly string[] = ["image/png", "image/jpeg", "image/gif", "image/webp", "image/heic", "image/heif", "image/tiff", "image/bmp"];
const EXT: Record<string, string> = { "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp",
  "image/heic": "heic", "image/heif": "heif", "image/tiff": "tiff", "image/bmp": "bmp" };

/// Only in a SECURE context. Measured on the iOS 26.5 simulator: `http://localhost` counts as one, the LAN
/// dev origin does not and has no `navigator.clipboard` at all.
export function canReadClipboard(nav: Navigator = navigator): boolean {
  return typeof nav.clipboard?.read === "function";
}

/// AN IMAGE WINS (a copied picture often carries its URL as text beside it), else plain text.
export function chooseClipboard(items: readonly { types: readonly string[] }[]): { item: number; type: string } | null {
  for (const [i, it] of items.entries()) {
    const t = it.types.find((x) => IMAGE_TYPES.includes(x));
    if (t) return { item: i, type: t };
  }
  for (const [i, it] of items.entries()) if (it.types.includes("text/plain")) return { item: i, type: "text/plain" };
  return null;
}

export type ClipboardRead = { ok: true; source: PasteSource } | { ok: false; why: "dismissed" | "empty" | "unavailable" };

/// CALL IT SYNCHRONOUSLY INSIDE THE CLICK that asked: `read()` needs the user activation, and iOS then shows
/// its own Paste bubble (measured: tapping it yields `text/plain` for copied text, `image/png` for a copied
/// photo). Dismissing the bubble rejects with `NotAllowedError`, so ANY rejection is a DISMISSAL — nothing
/// happens and nothing is said — never an error.
export function readClipboard(nav: Navigator = navigator): Promise<ClipboardRead> {
  if (!canReadClipboard(nav)) return Promise.resolve({ ok: false, why: "unavailable" });
  return nav.clipboard.read().then(async (items): Promise<ClipboardRead> => {
    const pick = chooseClipboard(items);
    if (!pick) return { ok: false, why: "empty" };
    const blob = await items[pick.item]?.getType(pick.type);
    if (!blob) return { ok: false, why: "empty" };
    if (pick.type === "text/plain") {
      const text = await blob.text();
      return text ? { ok: true, source: { kind: "text", text } } : { ok: false, why: "empty" };
    }
    return { ok: true, source: { kind: "file", name: `pasted.${EXT[pick.type] ?? "png"}`, type: pick.type, blob } };
  }, (): ClipboardRead => ({ ok: false, why: "dismissed" }));
}

/// The system picker — Photo Library, Take Photo, Choose File on iOS. Made per press and clicked INSIDE the
/// item's click (it needs the user activation). Resolves `[]` on cancel. iOS hands a HEIC photo over as
/// `image/jpeg` (it transcodes; measured), a PNG stays PNG.
export function pickFiles(doc: Document = document): Promise<File[]> {
  return new Promise((resolve) => {
    const input = doc.createElement("input");
    input.type = "file";
    input.multiple = true;
    input.style.display = "none";
    const done = (files: File[]) => { resolve(files); input.remove(); };
    input.addEventListener("change", () => done([...(input.files ?? [])]), { once: true });
    input.addEventListener("cancel", () => done([]), { once: true });
    doc.body.append(input);
    input.click();
  });
}

export function fileSources(files: readonly File[]): PasteSource[] {
  return files.map((f) => ({ kind: "file", name: fitName(f.name), type: fitType(f.type), blob: f }));
}

export function carriesFiles(dt: DataTransfer | null): boolean {
  return !!dt && [...dt.types].includes("Files");
}

/// A LINK: a browser's dragged link or image (the page's own palette thumbnails included) carries
/// `text/uri-list` — and a browser NAVIGATES to a link dropped where nothing takes it, exactly as to a file.
export function carriesLink(dt: DataTransfer | null): boolean {
  return !!dt && [...dt.types].includes("text/uri-list");
}

/// A drag or a paste carrying BOTH is files.
export function transferContents(dt: DataTransfer | null): { files: File[]; text: string | null } {
  if (!dt) return { files: [], text: null };
  const files = [...(dt.files ?? [])];
  if (files.length) return { files, text: null };
  const text = [...dt.types].includes("text/plain") ? dt.getData("text/plain") : "";
  return { files: [], text: text || null };
}
