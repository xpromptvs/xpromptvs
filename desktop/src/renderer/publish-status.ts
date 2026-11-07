/**
 * What the row says about this Mac's listing — as DATA, not DOM.
 *
 * WHY IT IS A SEPARATE MODULE: the renderer is otherwise untestable (no bundler, no test target), and
 * this is the exact seam where that cost something. The old `publishState()` in main was thoroughly
 * tested; the line a user actually reads was not — so a Mac could drop out of its owner's device list
 * while the window claimed "Published to your account."
 *
 * **THERE IS NO ACCOUNT ANY MORE.** Publication is signed by the device's certified key and reported
 * by the dylib (`rdev_host_publish_state`), so the input is one §12.2 word rather than a boolean and
 * an error string. `docs/superpowers/specs/2026-09-13-passkey-only-identity.md`.
 */
export interface PublishView {
  text: string;
  hidden: boolean;
  /// `warn` when the Mac is NOT listed. The renderer styles on this rather than parsing `text`.
  tone: "ok" | "warn";
}

/** Mirrors `Publication` in `host/RdevAppHost/Sources/RdevAppHost/SharingHost.swift`. */
export type PublicationState = "off" | "pending" | "confirmed" | "unconfirmed" | "rejected";

const SILENT: PublishView = { text: "", hidden: true, tone: "ok" };

export function publishStatus(state: PublicationState): PublishView {
  switch (state) {
    // Not sharing, or a Mac with no encryption identity to be listed under. Neither is a fault and
    // neither belongs here — the enrollment row is where "this Mac has no identity" is said, and
    // saying it twice in two voices is how two rows come to disagree.
    case "off": return SILENT;

    // **THE FIRST BEAT HAS NOT COME BACK YET, which is neither success nor failure.** It is bounded
    // by §12.2's 5 s deadline, after which it becomes one of the two below — so the honest thing for
    // those few seconds is to say nothing rather than flicker a claim and then withdraw it.
    case "pending": return SILENT;

    case "confirmed":
      return { text: "Your other devices can find this Mac.", hidden: false, tone: "ok" };

    // STILL TRYING vs REFUSED is the distinction that matters, and it is the one the old boolean
    // could not make. A transient failure retries on the next beat and needs nothing from the
    // person; a refusal will not fix itself.
    case "unconfirmed":
      return { text: "Not listed — retrying.", hidden: false, tone: "warn" };

    case "rejected":
      return { text: "Not listed — the control plane refused it.", hidden: false, tone: "warn" };
  }
}
