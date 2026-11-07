import type { ChannelLike } from "../lib/channel";
import { encodeJson } from "../lib/codec";
import { clientPrefsWire, type ClientPrefs } from "../shared/client-prefs";

// Parked at the user's request, 2026-10-30. Keep ordinary window/display/simulator capture.
// See docs/experiments/2026-10-25-app-workspace/parking-report.md before re-enabling.
export const APPLICATION_CAPTURE_ENABLED = false;

export interface ControlState { active: boolean; clients: number }
export interface SessionView { showClaim: boolean; showSim: boolean; sendResize: boolean }

/// Pure: map the host's control-state to what the UI should show.
export function viewForState(s: ControlState): SessionView {
  return {
    showClaim: !s.active,
    showSim: s.active,
    sendResize: s.active,
  };
}

/// What a client states to the host every time the control channel opens — about the CONNECTION, never
/// the session. The session (windows, terminals, the view) is the HOST's state and reaches the client in
/// `view-set` and `term-list`; a client that replayed its memory of it would fight the host's
/// (docs/superpowers/specs/2026-09-29-host-session-state-design.md). Everything here is kept by the host
/// only for the life of one connection, so a rebuild silently drops it unless it is stated again.
export interface ConnectionIntent {
  av1ReferenceAck?: 1;
  appsPackedV1?: boolean;
  /// A window-less connection: only what the terminal needs.
  windowless?: boolean;
  intendedRecoveryBp: number | null;
  /// The playout-delay floor to re-assert, in ms; null is Auto.
  intendedPlayoutDelayMs: number | null;
  /// The playout WINDOW (min = max) this client is in, in ms; null when it is on the floor design.
  /// FIRST AFTER THE SOURCE LIST: Chromium chooses its fast compositor path when the stream starts,
  /// and a window applied later moves only the timing clamp (measured 33 ms against 27; see
  /// `playout-floor.ts`, "THE WINDOW").
  intendedPlayoutWindowMs: number | null;
  /// The transport this connection wants for every window it is streamed. `?dc=1` is an instrument;
  /// the product is `rtp`. Per CONNECTION (CONTRACT ISSUE 1): a window the host restores must come back
  /// on the transport this client asked for, not on whatever the last client wanted.
  delivery: "rtp" | "dc";
  /// This client's xterm.js palette (`termPaletteMessage`), or null to send none. The host answers a
  /// tmux tab's colour queries whose bytes reach no client as the DRIVER's xterm.js would, and keeps a
  /// client's palette only for that connection (docs/terminal.md).
  termPalette: { t: "term-palette"; fg: string; bg: string; cursor: string; ansi: string[] } | null;
  /// `document.hidden` NOW. Stated on every open because the `set-visibility` sent from
  /// `visibilitychange` can be LOST — a phone's control channel is often dead when the page returns —
  /// and the host voids its media pause on a rebuild (docs/sources-and-focus.md).
  pageHidden: boolean;
  /// This DEVICE's preferences (`shared/client-prefs.ts`), carried by the hello.
  prefs: ClientPrefs;
}

/// Pure: the ordered control messages to send on control-open.
///
/// ONE ORDERING RULE: `client-hello` is LAST. The host starts a driver's video only once the hello has
/// arrived (the contract), so every setting the first frame depends on — the playout window above all —
/// is in before it.
export function controlOpenMessages(intent: ConnectionIntent): Array<{ t: string; [key: string]: unknown }> {
  const hello: { t: string; [key: string]: unknown } = { t: "client-hello", prefs: clientPrefsWire(intent.prefs) };
  if (intent.delivery === "dc") hello.delivery = "dc";
  if (intent.av1ReferenceAck === 1 && !intent.windowless && intent.delivery === "rtp") hello.av1ReferenceAck = 1;
  // A WINDOW-LESS CONNECTION STATES ONLY WHAT THE TERMINAL NEEDS. The host refuses every window and
  // media message from it (WindowlessPolicy); sending them would only fill its log with refusals.
  if (intent.windowless) return [...(intent.termPalette ? [intent.termPalette] : []), hello];
  const messages: Array<{ t: string; [key: string]: unknown }> = [{ t: "list-sources" }];
  if (intent.intendedPlayoutWindowMs !== null) {
    messages.push({ t: "set-playout-delay", minMs: intent.intendedPlayoutWindowMs, maxMs: intent.intendedPlayoutWindowMs });
  }
  // THE PAGE'S VISIBILITY, EVERY TIME. The host voids a hidden page's media pause when the driver
  // rebuilds, because the page's "visible" may have gone into the dead channel; a page still hidden
  // pauses again here.
  messages.push({ t: "set-visibility", hidden: intent.pageHidden });
  if (intent.termPalette) messages.push(intent.termPalette);
  // A FORCED RECOVERY PERCENTAGE IS PER-CONNECTION HOST STATE, so a peer rebuild drops it: the host
  // returns to adaptive and the user's deliberate choice is simply gone.
  if (intent.intendedRecoveryBp !== null) messages.push({ t: "set-recovery", overrideBp: intent.intendedRecoveryBp });
  // SAME RULE, SAME REASON for the floor — replaced by the window when there is one.
  if (intent.intendedPlayoutDelayMs !== null && intent.intendedPlayoutWindowMs === null) {
    messages.push({ t: "set-playout-delay", minMs: intent.intendedPlayoutDelayMs });
  }
  const apps = APPLICATION_CAPTURE_ENABLED && intent.appsPackedV1 === true;
  if (intent.appsPackedV1 !== undefined) messages.push({ t: "apps-capabilities", packedV1: apps });
  if (apps) messages.push({ t: "apps-list" });
  messages.push(hello);
  return messages;
}

/// Narrow a decoded control-channel JSON message to a ControlState, or null if it isn't one.
export function parseControlState(msg: unknown): ControlState | null {
  if (typeof msg !== "object" || msg === null) return null;
  const m = msg as { t?: unknown; active?: unknown; clients?: unknown };
  if (m.t !== "control-state" || typeof m.active !== "boolean" || typeof m.clients !== "number") return null;
  return { active: m.active, clients: m.clients };
}

/// How long a "Move here" stays WANTED without an answer (docs/client-web.md, "Move here survives the connection"):
/// said again on every control channel that opens meanwhile, then forgotten — the button says "Move here" again.
export const CLAIM_INTENT_MS = 30_000;

/// Applies active/passive to the DOM and owns the claim-control sender. The sim overlay is hidden via
/// the `.hidden` class when passive; the claim overlay is shown.
export class SessionControl {
  private active = false;
  /// A Move here the person asked for and the host has not answered (`claim`): its expiry's cancel.
  private claimed: { cancel: () => void } | null = null;
  private readonly claimLabel: Text | null;
  constructor(
    private control: ChannelLike,   // mutable: rebind() swaps it to the live channel after a PC rebuild
    private readonly els: { sim: HTMLElement; claim: HTMLElement; claimButton: HTMLElement },
    private readonly onActivate: () => void,
    private readonly onDeactivate?: () => void,
    /// `document.hidden`, read when this client BECOMES the driver — see `apply`.
    private readonly pageHidden: () => boolean = () => false,
    /// `windowless`: a connection with no media (docs/client-web.md). Its activation states the
    /// TERMINAL's visibility only — the host refuses its `set-visibility` (WindowlessPolicy), and
    /// sending one would only log a refusal. Absent, the connection is windowed, as it always was.
    /// `claimGrid`: the terminal grid a claim says (docs/terminal.md, "A claim says its grid") — measured when the
    /// claim is sent; null or absent, the claim carries none.
    /// `timer`: the session's (released with it) — runs `f` after `ms`, returns its cancel. Absent: `setTimeout`.
    private readonly options: { terminalHidden?: () => boolean; windowless?: boolean; claimGrid?: () => { cols: number; rows: number } | null;
                                timer?: (f: () => void, ms: number) => () => void } = {},
  ) {
    this.claimLabel = [...els.claimButton.childNodes].find((n): n is Text => n.nodeType === 3 && !!n.textContent?.trim()) ?? null;
    els.claimButton.addEventListener("click", () => this.claim());
  }

  get isActive(): boolean { return this.active; }

  /// Point future claim() sends at a freshly-negotiated control channel (PC rebuild on connection loss).
  /// The DOM (claim button) listener is bound once in the constructor and is NOT re-added here, so calling
  /// this on every rebuild is safe. SessionControl adds no channel listeners of its own — the control-state
  /// messages are dispatched centrally in main.ts — so there's nothing else to re-wire.
  rebind(control: ChannelLike): void { this.control = control; }

  apply(state: ControlState): void {
    const v = viewForState(state);
    this.els.claim.classList.toggle("hidden", !v.showClaim);
    this.els.sim.classList.toggle("hidden", !v.showSim);
    const became = !this.active && state.active;
    const lost = this.active && !state.active;
    this.active = state.active;
    // BECOMING THE DRIVER STATES THE PAGE'S VISIBILITY, before anything the activation sends: the
    // host voids the outgoing driver's media pause on a change of driver, and a promoted page may be
    // hidden (its reports while passive were ignored). docs/sources-and-focus.md.
    // The TERMINAL's too (final review M2): the host clears its terminal pause on a change of driver,
    // so a hidden promoted page would have every tab streamed into it and every query in them counted
    // as reached by an instance that cannot answer. The same statement `negotiateRaw` makes on a
    // control open; a repeat is harmless (a pause re-arms its 1 s hold, a resume lifts nothing new).
    if (became && this.control.readyState === "open") {
      const hidden = this.pageHidden();
      if (!this.options.windowless) this.control.send(encodeJson({ t: "set-visibility", hidden }) as Uint8Array<ArrayBuffer>);
      this.control.send(encodeJson({ t: (this.options.terminalHidden?.() ?? hidden) ? "terminal-pause" : "terminal-resume" }) as Uint8Array<ArrayBuffer>);
    }
    if (state.active) this.forgetClaim();   // answered — or already so
    if (became) this.onActivate();   // active page sends an immediate resize
    if (lost) this.onDeactivate?.();
  }

  /// **MOVE HERE SURVIVES THE CONNECTION** (docs/client-web.md; 2026-10-06, "move here often doesnt work on mobile"):
  /// the claim is WANTED until the host says this page drives or `CLAIM_INTENT_MS` passes — said now if the control
  /// channel is open, and again on every control channel that opens meanwhile (`reclaim`). A phone brought back from
  /// the background is often mid-rebuild, or holds a channel that reads open and delivers nothing: the claim was sent
  /// into it (or not at all, closed) and lost, with nothing to show the tap had been taken. The button says
  /// "Moving here…" while it waits.
  claim(): void {
    this.claimed?.cancel();
    const set = this.options.timer ?? ((f, ms) => { const t = setTimeout(f, ms); return () => clearTimeout(t); });
    this.claimed = { cancel: set(() => this.forgetClaim(), CLAIM_INTENT_MS) };
    this.showClaimWanted(true);
    this.sendClaim();
  }

  /// A control channel OPENED (a rebuild, a reconnect — after its open batch, so the host has this page's hello):
  /// a Move here still wanted is said on it.
  reclaim(): void {
    if (this.claimed && !this.active) this.sendClaim();
  }

  private sendClaim(): void {
    if (this.control.readyState !== "open") return;
    const grid = this.options.claimGrid?.() ?? null;
    this.control.send(encodeJson(grid ? { t: "claim-control", cols: grid.cols, rows: grid.rows } : { t: "claim-control" }) as Uint8Array<ArrayBuffer>);
  }

  private forgetClaim(): void {
    if (!this.claimed) return;
    this.claimed.cancel();
    this.claimed = null;
    this.showClaimWanted(false);
  }

  private showClaimWanted(on: boolean): void {
    this.els.claimButton.setAttribute("aria-busy", String(on));
    if (this.claimLabel) this.claimLabel.textContent = on ? "Moving here…" : "Move here";
  }
}
