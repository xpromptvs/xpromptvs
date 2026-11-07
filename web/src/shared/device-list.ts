import type { Surface } from "./surface";

/**
 * **The Macs in this identity that are sharing right now** — as DATA, then as DOM.
 *
 * **ONE implementation, TWO surfaces.** The browser dashboard (`#welcome`, `web/src/client/welcome.ts`)
 * and the native app's own dashboard (`app://ui/`, `desktop/src/renderer/main.ts`) show the same
 * list of the same Macs, from the same §12.2 directory. They were two hand-written copies until
 * 2026-09-14, and they had already drifted: the resting word under a Mac's name read "Listed" in one
 * and "Online" in the other, the rows wore two different class vocabularies that `shell.css` and
 * `motion.js` each had to name twice, and only one of them carried `data-session-code` — so the
 * check that counts rows was measuring nothing on the other. **The word is "Online" again since
 * 2026-09-15** — see the render site below for why the argument against it did not survive being
 * measured. What the unification bought is that there is now one answer to change, not two.
 * `docs/ui-design.md`.
 *
 * What the surfaces genuinely differ in is ONE sentence, and it is the `surface` parameter below.
 * A browser and — since 2026-10-06, natively — a Mac with no identity both sign in with a passkey
 * here; the app's own client window cannot, because its Mac certifies it instead.
 *
 * This replaced the account panel. There is no sign-in, no name and no email: a browser that holds a
 * chain under a root asks §12.2's directory for that root's live rooms, signed with its own key
 * (`lib/directory-api.ts`). `docs/superpowers/specs/2026-09-13-passkey-only-identity.md`.
 *
 * The DECISION is `deviceListView`, pure and tested, for the reason `e2eSetupView` is: what a person
 * reads is the whole product of this module, and jsdom can assert a string where it cannot assert a
 * layout.
 *
 * **A LISTING IS A HINT.** §12.2: absence is never revocation, and §4 puts the Worker inside the
 * adversary model. Every sentence here is written so that a missing row reads as "not listed", never
 * as "gone" — and a row is an invitation to try a room, which §11's gate then decides.
 */

/**
 * The least a row needs to be drawn. **Deliberately structural, not `DirectorySession`**: the
 * browser reads that type off the directory and carries a room token beside it, while the app reads
 * `{name, code}` back out of its host. Naming the wire type here would force one of them to invent
 * the fields it does not have, and a dummy token in a row is exactly the value that must not exist.
 */
export interface DeviceRowInput {
  /** What a person reads. Never markup: a label is a remote Mac's assertion about itself. */
  label: string;
  /** The room code, which is what a caller passes back to connect. The TOKEN is not here. */
  code: string;
}

/**
 * Which dashboard is asking. It changes exactly one sentence — see `no-identity` below — and it is a
 * parameter rather than two states so that the difference is READ SIDE BY SIDE instead of living in
 * two files that are free to drift apart. `surface.ts` has the whole list of such differences.
 */
export type DeviceListSurface = Surface;

export type DeviceListState<T extends DeviceRowInput = DeviceRowInput> =
  /** This surface holds no chain, so there is no identity whose rooms it could ask for. */
  | { kind: "no-identity" }
  | { kind: "loading" }
  /**
   * `stale` means these rows are the LAST ones the directory gave, repainted because the latest
   * attempt failed — `"offline"` when the browser itself says it has no network. A weak network fails
   * one listing in several, and blanking a list the person was about to click on every such failure
   * is worse than showing the rows with a line saying they may be out of date. Stale rows still
   * connect: a listing was only ever a hint, and §11's gate decides either way.
   */
  | { kind: "ready"; devices: readonly T[]; stale?: StaleReason }
  /** The directory did not answer, and there is nothing earlier to show. NOT "you have no Macs". */
  | { kind: "unreachable"; offline?: boolean };

export type StaleReason = "unreachable" | "offline";

/** A row as the view hands it out: the same two fields, with the label already normalised. */
export type DeviceRow = DeviceRowInput;

/** The only thing a person can do from this list that is not connecting to a Mac. */
export type DeviceListAction = "sign-in";

export interface DeviceListView {
  message: string;
  devices: DeviceRow[];
  /** Empty until a count is meaningful — "0" while loading would read as an answer. */
  count: string;
  /** A renderer shows a Refresh control only where refreshing could change anything. */
  canRefresh: boolean;
  /** Offered ONLY where a passkey could change the answer. */
  actions: Array<{ id: DeviceListAction; label: string }>;
  tone: "info" | "warn";
}

/** A Mac that published no name SAYS SO, rather than wearing a word every row would share. */
const UNNAMED = "Unnamed Mac";

const NO_IDENTITY: Record<DeviceListSurface, string> = {
  browser: "Sign in with your Mac’s passkey using Touch ID or your phone.",
  mac: "Sign in or create a passkey with Touch ID or your phone.",
  "app-client": "This window has no encryption identity yet — it gets one from this Mac once this "
              + "Mac is set up for end-to-end encryption, and your Macs will appear here after "
              + "that. Open Settings in Xpromptvs on this Mac to finish setup.",
};

export function deviceListView (state: DeviceListState, surface: DeviceListSurface): DeviceListView {
  switch (state.kind) {
    // **THIS IS WHERE SIGNING IN LIVES, and it is the only state that offers it.** §10.1's root is a
    // discoverable credential, so a person who already has one on this device — or on a phone, over
    // the platform's cross-device flow — can reach their Macs here without a pairing code and
    // without an account. It replaced the Sign in button that stood in this spot, and it is the half
    // of that removal that was missing while the list could only ever say "pair with a Mac".
    //
    // A device that holds an identity is NOT offered it: there is nothing a second passkey would
    // change, and §10.1 forbids replacing a root that is already trusted.
    //
    // **A MAC IS OFFERED IT TOO** since 2026-10-06: the app runs the passkey ceremony natively
    // (`docs/e2e.md`, "The Mac's own passkey ceremony") — the same panel, opened from here or from
    // the encryption row further up the page, which adds the other route onto a Mac (a code).
    //
    // **THE APP'S CLIENT WINDOW is offered nothing either**, for the Mac's reason, but its sentence
    // is about the WINDOW: the Mac certifies it (§10.3) as soon as the window OPENS (`welcome.ts`),
    // so a person sees this sentence only where that certification cannot happen — a Mac not yet
    // set up, or one added by code (capability `2`) that cannot issue. Connecting does not help
    // there, which is why it no longer says "on its first connect" (true only before 2026-09-26);
    // on an enrolled Mac the list holds "Looking…" while the adoption is in flight instead.
    case "no-identity":
      return {
        message: NO_IDENTITY[surface],
        devices: [], count: "", canRefresh: false,
        actions: surface === "app-client"
          ? []
          : [{ id: "sign-in", label: "Sign in with a passkey" }],
        tone: "info",
      };

    case "loading":
      return { message: "Looking for your Macs…", devices: [], count: "", canRefresh: false,
               actions: [], tone: "info" };

    case "ready": {
      const devices = state.devices.map((d) => ({
        label: d.label.trim() === "" ? UNNAMED : d.label.trim(),
        code: d.code,
      }));
      if (state.stale) {
        // An earlier EMPTY answer has nothing to vouch for; say what is true now instead.
        if (devices.length === 0) {
          return deviceListView({ kind: "unreachable", offline: state.stale === "offline" }, surface);
        }
        return {
          message: state.stale === "offline"
            ? "You're offline — these are the Macs listed last time. The list refreshes by itself "
            + "when the connection is back."
            : "Could not refresh — these are the Macs listed last time. Retrying automatically.",
          devices, count: String(devices.length), canRefresh: true, actions: [], tone: "warn",
        };
      }
      return {
        // **"NOT LISTED", NEVER "NOT SHARING".** §12.2 forbids reading absence as revocation, and a
        // Mac that is sharing perfectly well is absent from this list whenever its publication is
        // failing — which is a fault on the other Mac and says nothing about access.
        message: devices.length === 0
          ? "None of your Macs is listed right now. On the Mac you want to use, open Xpromptvs, "
          + "sign in with the same passkey, and turn on Sharing."
          : "",
        devices,
        count: String(devices.length),
        canRefresh: true, actions: [], tone: "info",
      };
    }

    case "unreachable":
      return {
        message: state.offline
          ? "You're offline. Your Macs will appear here by themselves when the connection is back."
          : "Could not reach the device directory. Retrying automatically. Your Macs may still be "
          + "sharing. The list will update when the connection is back.",
        devices: [], count: "", canRefresh: true, actions: [], tone: "warn",
      };
  }
}

// ------------------------------------------------------------------ the DOM half

/**
 * **ONE ROW, drawn the same way wherever a Mac is offered**: the listed Macs (`renderDeviceList`), and
 * the app's own "This Mac" above them (`dashboard.ts`).
 * - `code` is null for a row that is not a listed room. It then carries no `data-session-code`, so
 *   nothing that counts LISTED Macs counts it.
 * - `state` is the row's RESTING word, kept on the row (`data-resting-state`) for `motion.js`'s
 *   `unlight` to put back when a connection ends.
 */
export function deviceRow (opts: { label: string; code: string | null; state: string; navId: string;
                                   onConnect: (row: HTMLElement) => void }): HTMLElement {
  const row = document.createElement("div");
  row.className = "ss-device";
  // **Carried on BOTH dashboards.** It is how `motion.js` gives a row a stable identity across
  // repaints, and it is what every check counts — an arm that lacked it was asserting zero rows
  // against a list that had two.
  if (opts.code !== null) row.setAttribute("data-session-code", opts.code);
  row.dataset.restingState = opts.state;

  const icon = document.createElement("span");
  icon.className = "ss-device-icon";
  icon.setAttribute("aria-hidden", "true");
  icon.innerHTML = '<svg viewBox="0 0 24 24"><rect x="3" y="4" width="18" height="13" rx="2"/><path d="M8 21h8M12 17v4"/></svg>';

  const copy = document.createElement("span");
  copy.className = "ss-device-copy";
  const name = document.createElement("span");
  name.className = "ss-device-name";
  name.textContent = opts.label;          // TEXT, never markup
  const status = document.createElement("span");
  status.className = "ss-device-state";
  status.textContent = opts.state;
  copy.append(name, status);

  const action = document.createElement("button");
  action.type = "button";
  action.className = "ss-connect-label";
  action.textContent = "Connect";
  action.setAttribute("aria-label", `Connect to ${opts.label}`);
  action.dataset.navId = opts.navId;
  action.addEventListener("click", () => opts.onConnect(row));

  row.append(icon, copy, action);
  return row;
}

/**
 * Paint `deviceListView` and carry clicks back. DOM glue only, in the split `command-palette.ts`
 * uses: everything worth arguing about is above, and a jsdom test of this half could only assert
 * against itself.
 *
 * **Built with `createElement` and `textContent`, never `innerHTML`.** A label is a remote Mac's
 * assertion about itself, relayed by a Worker inside the adversary model — the one string on this
 * page most worth never interpolating into markup. The static artwork is the only exception and
 * contains no data.
 *
 * **The class vocabulary is `ss-device*`, and it is the ONLY one.** `shell.css` is shared by both
 * dashboards and `motion.js` decorates rows on both; while the browser emitted `.account-session`
 * and the app emitted `.ss-device`, every rule and every selector in those two files had to name a
 * pair — and one of the pair was silently missed more than once (`.ss-home .ss-device[aria-busy]`,
 * which lights a connecting row's screen, never matched a browser row at all).
 */
export function renderDeviceList (opts: {
  root: HTMLElement;
  /** Which dashboard this is. See `DeviceListSurface`. */
  surface: DeviceListSurface;
  countRoot?: HTMLElement | null;
  /** The renderer OWNS the refresh control: it exists exactly where refreshing could change something. */
  refreshRoot?: HTMLElement | null;
  onConnect: (code: string, row: HTMLElement) => void;
  onRefresh: () => void;
  onAction: (id: DeviceListAction) => void;
}): (state: DeviceListState) => void {
  const { root, surface, onConnect, onRefresh, onAction } = opts;

  return (state: DeviceListState): void => {
    const view = deviceListView(state, surface);
    root.replaceChildren();
    if (opts.countRoot) opts.countRoot.textContent = view.count;

    if (opts.refreshRoot) {
      opts.refreshRoot.replaceChildren();
      if (view.canRefresh) {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "ss-text-action";
        button.textContent = "refresh";
        button.setAttribute("aria-label", "Refresh devices");
        button.title = "Refresh devices";
        // The glasses D-pad reaches only `[data-nav-id]`; carried at the render site (docs/glasses.md).
        button.dataset.navId = "home:refresh";
        button.addEventListener("click", () => onRefresh());
        opts.refreshRoot.appendChild(button);
      }
    }

    if (view.message !== "") {
      const p = document.createElement("p");
      p.className = view.tone === "warn" ? "ss-device-message warn" : "ss-device-message";
      p.textContent = view.message;
      root.appendChild(p);
    }

    for (const action of view.actions) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "device-list-action";
      button.dataset.deviceAction = action.id;
      button.dataset.navId = `home:action:${action.id}`;
      button.textContent = action.label;
      button.addEventListener("click", () => onAction(action.id));
      root.appendChild(button);
    }

    for (const device of view.devices) {
      // **"Online" — the directory heartbeat is a liveness signal, and it is fair to say so.**
      // This read "Listed" between 2026-09-14 and 2026-09-15 on the reasoning that §12.2 makes a
      // listing a hint rather than a claim about reach. Half of that survives and half did not:
      // ABSENCE still proves nothing (a Mac drops out of the list for many reasons, and §12.2
      // says absence is not revocation), but PRESENCE is stronger than "listed" admits —
      // `DirectoryDO` runs a 30 s heartbeat against a 90 s TTL (`control-plane/src/directory-do.ts`),
      // so a row on this screen published within the last 90 seconds.
      //
      // The other half of that argument was simply wrong, and measuring it is what settled this:
      // "a resting row already wearing the word has nothing to change into" assumed the word is
      // what a connecting row shows. It is not. `motion.js` writes "Online" into this element at
      // ignite and then calls `phase("Waiting for connection…")` in the SAME synchronous block, so
      // nothing paints in between — that write is a PRIMING sentinel for the reveal animation, and
      // a person never reads it. The visible states are all distinct: Online → Waiting for
      // connection… → Connected → Online.
      //
      // The nav id is keyed on the CODE, not the label: two Macs may share a name, and `homeNavOrder`
      // enters the glasses D-pad at the first `device:` id. **The room TOKEN is never written to an
      // attribute or a text node.** The caller holds it; this hands back a code and lets it look the row up.
      root.appendChild(deviceRow({ label: device.label, code: device.code, state: "Online",
                                   navId: `device:${device.code}`, onConnect: (row) => onConnect(device.code, row) }));
    }
  };
}
