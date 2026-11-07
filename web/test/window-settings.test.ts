import { describe, it, expect } from "vitest";
import {
  SETTINGS_ROWS, settingsRowLabel, visibleSettingsRows, mountSettingsChoice,
  syncSettingsChoice, type SettingsRow,
} from "../src/client/window-settings";

it("uses the tab-menu popover for a mobile setting and keeps the select as its source of truth", () => {
  const proto = HTMLElement.prototype as unknown as { showPopover?: () => void; hidePopover?: () => void };
  const matches = Element.prototype.matches;
  proto.showPopover = function (this: HTMLElement) { this.dataset.open = "1"; };
  proto.hidePopover = function (this: HTMLElement) { delete this.dataset.open; };
  Element.prototype.matches = function (this: Element, selector: string) {
    return selector === ":popover-open" ? (this as HTMLElement).dataset.open === "1" : matches.call(this, selector);
  };
  const controller = new AbortController();
  try {
    const select = document.createElement("select");
    select.innerHTML = '<option value="auto">Auto</option><option value="20">20%</option>';
    select.setAttribute("aria-label", "Forced FEC overhead (all windows)");
    const button = mountSettingsChoice(select, controller.signal);
    document.body.append(select, button);
    syncSettingsChoice(select);
    expect(button.textContent).toBe("Auto");
    expect(button.getAttribute("aria-label")).toBe(select.getAttribute("aria-label"));
    let changes = 0;
    select.addEventListener("change", () => changes++);
    button.click();
    const menu = document.querySelector(".win-settings-choice-menu")!;
    expect(menu.querySelector('[data-action="auto"]')?.getAttribute("aria-checked")).toBe("true");
    menu.querySelector<HTMLButtonElement>('[data-action="20"]')!.click();
    expect([select.value, button.textContent, changes]).toEqual(["20", "20%", 1]);
  } finally {
    controller.abort();
    document.body.innerHTML = "";
    delete proto.showPopover;
    delete proto.hidePopover;
    Element.prototype.matches = matches;
  }
});

describe("settings row scope", () => {
  it("labels a host-wide row distinctly from a session-wide one", () => {
    // THE SCOPE WORD IS THE WHOLE POINT. A host-wide control rendered like a per-window one is how
    // someone comes to believe their setting is narrower than it is — the same reasoning that put
    // "(all windows)" on the FEC row. `host` is broader again: it outlives this connection and
    // changes the physical Mac.
    expect(settingsRowLabel({ key: "curtain", label: "Curtain", scope: "host", focusable: true }))
      .toBe("Curtain (this Mac)");
    expect(settingsRowLabel({ key: "recovery", label: "Forced FEC overhead", scope: "session", focusable: true }))
      .toBe("Forced FEC overhead (all windows)");
    expect(settingsRowLabel({ key: "fps", label: "Frame rate", scope: "window", focusable: true }))
      .toBe("Frame rate");
  });

  it("includes exactly one curtain row, and it is focusable", () => {
    const curtain = SETTINGS_ROWS.filter((r) => r.key === "curtain");
    expect(curtain).toHaveLength(1);
    // A control the D-pad can land on but not activate is a dead stop with no pointer to escape it.
    expect(curtain[0]?.focusable).toBe(true);
    expect(curtain[0]?.scope).toBe("host");
  });

  it("keeps every row's scope explicit", () => {
    // No row may default its scope: the omission is invisible and renders as per-window.
    const scopes: SettingsRow["scope"][] = ["window", "session", "device", "host"];
    for (const r of SETTINGS_ROWS) expect(scopes).toContain(r.scope);
  });

  // THE STREAM SETTINGS ARE THIS DEVICE'S (asked for 2026-09-29): one frame rate, resolution, bitrate
  // and codec for every window a device streams, so each row says so — the rule for a control that
  // reaches further than the window it was opened from.
  it("keeps bitrate device-wide and codec read-only at the bottom", () => {
    expect(SETTINGS_ROWS.find(r => r.key === "bitrate")?.scope).toBe("device");
    expect(SETTINGS_ROWS.at(-1)).toMatchObject({ key: "codec", scope: "window", focusable: false });
    expect(SETTINGS_ROWS.some(r => ["fps", "scale", "pointer"].includes(r.key))).toBe(false);
  });

  it("still marks the two session-wide rows as session-wide", () => {
    // Regression guard for the sessionWide -> scope migration: a mechanical rename could silently
    // give a row the wrong scope, and only these two are session-wide.
    const session = SETTINGS_ROWS.filter((r) => r.scope === "session").map((r) => r.key);
    expect(session.sort()).toEqual(["delay", "recovery"]);
  });
});

describe("layout-scoped rows", () => {
  it("labels a device-wide row distinctly", () => {
    expect(settingsRowLabel({ key: "pointer", label: "Touch mode", scope: "device", focusable: true }))
      .toBe("Touch mode (this device)");
  });

  it("moves touch mode out of settings on every layout", () => {
    for (const m of ["floating", "tabbed", "glasses"] as const)
      expect(visibleSettingsRows(m).map(r => r.key)).not.toContain("pointer");
  });

  it("hides nothing else on any layout", () => {
    // A row gated to one layout is the #palette-close trap. Only `pointer` may be gated, and only
    // because it is the sole route to a mode that is meaningless where it is hidden.
    for (const m of ["floating", "tabbed", "glasses"] as const) {
      const hidden = SETTINGS_ROWS.filter((r) => !visibleSettingsRows(m).includes(r)).map((r) => r.key);
      expect(hidden.every((k) => k === "pointer")).toBe(true);
    }
  });
});
