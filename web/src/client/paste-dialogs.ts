import type { FolderQuestion } from "./paste-local";
import type { ClientContext } from "./instance/context";
import { openClientDialog, closeClientDialog } from "./instance/overlays";

/** Questions belong to their presenting root. Replacing or disposing one always settles its promise. */
export function createPasteDialogs({ get, scope }: Pick<ClientContext, "get" | "scope">) {
  let pasteQuestion: ((yes: boolean) => void) | null = null;
  /// Several lines into a program NOT in bracketed paste mode each run as they arrive, so a paste from the
  /// menu or a drop asks first (paste-and-drop design §2.4) — a modal like the kill confirmation, its
  /// title the question and its body the reason. Escape, Cancel and the session closing it all say no.
  function confirm(question: string, yes = "Paste"): Promise<boolean> {
    const d = get<HTMLDialogElement>("paste-lines-dialog");
    pasteQuestion?.(false);                 // one modal: a question still up is answered no, closed and replaced
    pasteFolderChoice?.(null);
    const cut = question.indexOf("? ");
    get("paste-lines-title").textContent = cut < 0 ? question : question.slice(0, cut + 1);
    get("paste-lines-body").textContent = cut < 0 ? "" : question.slice(cut + 2);
    get("paste-lines-confirm").textContent = yes;
    return new Promise((resolve) => {
      const answer = (yes: boolean) => {
        if (pasteQuestion !== answer) return;
        pasteQuestion = null;
        resolve(yes);
        if (d.open) closeClientDialog(d);
      };
      pasteQuestion = answer;
      get("paste-lines-confirm").onclick = () => answer(true);
      get("paste-lines-cancel").onclick = () => answer(false);
      // `close` fires a task after `close()`: a dialog open again by then is the NEXT question's.
      d.onclose = () => { if (!d.open) answer(false); };
      if (!d.open) openClientDialog(d);
    });
  }
  /// The open folder question's ANSWER (`askFolderChoice`), which closes its dialog, null with none up.
  let pasteFolderChoice: ((c: "path" | "send" | null) => void) | null = null;
  /// FOLDERS PASTED TO ANOTHER MAC (the app; paste-local.ts): this Mac's path, the folder zipped and sent, or
  /// nothing — a modal like the paste question, and like it answered "nothing" by Escape and the session ending.
  function chooseFolder(q: FolderQuestion): Promise<"path" | "send" | null> {
    const d = get<HTMLDialogElement>("paste-folder-dialog");
    pasteFolderChoice?.(null);
    pasteQuestion?.(false);
    get("paste-folder-title").textContent = q.title;
    get("paste-folder-body").textContent = q.body;
    get("paste-folder-path").textContent = q.path;
    get("paste-folder-send").textContent = q.send;
    return new Promise((resolve) => {
      const answer = (c: "path" | "send" | null) => {
        if (pasteFolderChoice !== answer) return;
        pasteFolderChoice = null;
        resolve(c);
        if (d.open) closeClientDialog(d);
      };
      pasteFolderChoice = answer;
      get("paste-folder-path").onclick = () => answer("path");
      get("paste-folder-send").onclick = () => answer("send");
      get("paste-folder-cancel").onclick = () => answer(null);
      // `close` fires a task after `close()`: a dialog open again by then is the NEXT question's.
      d.onclose = () => { if (!d.open) answer(null); };
      if (!d.open) openClientDialog(d);
    });
  }

  scope.defer(() => { pasteQuestion?.(false); pasteFolderChoice?.(null); }, "paste-dialogs");
  return { confirm, chooseFolder };
}
