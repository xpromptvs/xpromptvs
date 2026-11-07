import { describe, expect, it } from "vitest";
import { visibleSettingsRows } from "../src/client/window-settings";
import { homeNavOrder, navOrder, navStep, type NavState } from "../src/client/spatial-nav";

const base: NavState = {
  screen: "sources",
  sources: [{ id: "win:1", minimized: false }, { id: "win:2", minimized: true }],
  terminals: [{ id: "t1" }],
  paletteOpen: false, settingsOpen: false,
  active: true,
  paletteEntries: [],
  termEmpty: [],
  dialog: null,
};

describe("navOrder — tmux terminals", () => {
  it("an EMPTY terminal offers its buttons instead of the chips — there is nothing to type into", () => {
    const order = navOrder({ ...base, screen: "terminal", terminals: [], termEmpty: ["term-empty:new", "term-empty:new-tmux"] });
    expect(order).toEqual(["tab:win:win:1", "tab:win:win:2", "add", "palette", "term-empty:new", "term-empty:new-tmux"]);
    expect(order).not.toContain("compose");
  });

  it("an open confirmation is a TRAP: only its own buttons", () => {
    const order = navOrder({ ...base, screen: "terminal", dialog: ["tmux-kill:cancel", "tmux-kill:confirm"] });
    expect(order).toEqual(["tmux-kill:cancel", "tmux-kill:confirm"]);
  });
});

describe("navOrder — the bar's order (tab menu, 2026-10-01)", () => {
  it("walks the tabs in the BAR's order when the bar interleaves them", () => {
    const order = navOrder({ ...base, tabOrder: ["win:2", "t1", "win:1"] });
    expect(order.slice(0, 5)).toEqual(["tab:win:win:2", "tab:term:t1", "tab:win:win:1", "add", "palette"]);
  });

  it("without one, the terminals then the windows", () => {
    expect(navOrder(base).slice(0, 3)).toEqual(["tab:term:t1", "tab:win:win:1", "tab:win:win:2"]);
  });
});

describe("navOrder", () => {
  it("puts the strip first, then the screen's own controls", () => {
    expect(navOrder(base)).toEqual([
      "tab:term:t1", "tab:win:win:1", "tab:win:win:2", "add", "palette",
      "src:win:1", "src:win:2",
    ]);
  });

  it("lists a minimized source — it is a live way back, not a dead entry", () => {
    expect(navOrder(base)).toContain("src:win:2");
  });

  it("the terminal screen exposes the compose bar and every key chip", () => {
    const order = navOrder({ ...base, screen: "terminal" });
    expect(order.slice(-10)).toEqual([
      "compose",
      "chip:enter", "chip:backspace", "chip:tab", "chip:esc", "chip:ctrlc",
      "chip:up", "chip:down", "chip:left", "chip:right",
    ]);
  });

  it("carries a full set of arrow chips — the physical D-pad can never reach the shell", () => {
    const order = navOrder({ ...base, screen: "terminal" });
    for (const dir of ["up", "down", "left", "right"]) expect(order).toContain(`chip:${dir}`);
  });

  it("the window screen exposes only its own three controls", () => {
    const order = navOrder({ ...base, screen: "window" });
    expect(order.slice(-3)).toEqual(["win:back", "win:minimize", "win:close"]);
  });

  it("an open palette TRAPS focus — nothing behind it is reachable", () => {
    const order = navOrder({ ...base, paletteOpen: true });
    expect(order).toEqual(["palette:input", "palette:close"]);
    expect(order.some((id) => id.startsWith("tab:"))).toBe(false);
  });

  it("walks the palette's rows and tiles in visual order, between the field and the ✕", () => {
    const order = navOrder({
      ...base, paletteOpen: true, settingsOpen: false,
      paletteEntries: ["palette:action:new-terminal", "palette:source:win:1", "palette:source:win:2"],
    });
    expect(order).toEqual([
      "palette:input",
      "palette:action:new-terminal", "palette:source:win:1", "palette:source:win:2",
      "palette:close",
    ]);
  });

  it("keeps the trap with entries present — the grid must not be a way out of the sheet", () => {
    const order = navOrder({
      ...base, paletteOpen: true, settingsOpen: false, paletteEntries: ["palette:source:win:1"],
    });
    expect(order.some((id) => id.startsWith("tab:") || id.startsWith("chip:"))).toBe(false);
  });

  it("a passive client gets no palette entries even when the sheet is open", () => {
    // Every tile maps to a host-gated subscribe the host would reject.
    expect(navOrder({
      ...base, active: false, paletteOpen: true, settingsOpen: false, paletteEntries: ["palette:source:win:1"],
    })).toEqual(["claim"]);
  });

  it("a passive client can reach only the claim button", () => {
    expect(navOrder({ ...base, active: false })).toEqual(["claim"]);
  });

  it("a passive client is gated even with the palette open", () => {
    expect(navOrder({ ...base, active: false, paletteOpen: true })).toEqual(["claim"]);
  });
});

describe("navStep", () => {
  const order = ["a", "b", "c"];

  it("advances and retreats", () => {
    expect(navStep(order, "a", 1)).toBe("b");
    expect(navStep(order, "b", -1)).toBe("a");
  });

  it("WRAPS at both ends — a wearer must never hit a dead end", () => {
    expect(navStep(order, "c", 1)).toBe("a");
    expect(navStep(order, "a", -1)).toBe("c");
  });

  it("enters at the first control when nothing is focused", () => {
    expect(navStep(order, null, 1)).toBe("a");
    expect(navStep(order, null, -1)).toBe("a");
  });

  it("re-enters at the first control when focus is on something that vanished", () => {
    expect(navStep(order, "gone", 1)).toBe("a");
  });

  it("returns null for an empty order rather than throwing", () => {
    expect(navStep([], null, 1)).toBeNull();
  });
});

describe("settings panel is a modal nav surface", () => {
  const base = {
    screen: "window" as const,
    sources: [{ id: "win:1", minimized: false }],
    terminals: [{ id: "1" }],
    paletteOpen: false, settingsOpen: false, active: true, paletteEntries: [], termEmpty: [], dialog: null,
  };

  it("puts the gear on the window screen", () => {
    expect(navOrder(base)).toContain("win:settings");
  });

  it("reaches nothing behind it while open, and ends at the way out", () => {
    const order = navOrder({ ...base, settingsOpen: true });
    // A TRAP, like the palette: the panel covers the screen on this layout, so anything behind it is
    // invisible and a pinch there would fire a control the wearer cannot see.
    expect(order).not.toContain("win:settings");
    expect(order).not.toContain("tab:term:t1");
    expect(order).not.toContain("win:close");
    // Paired with the trap: a surface nothing can leave is satisfied by focus never moving, so the
    // close must be present AND last.
    expect(order.at(-1)).toBe("win:settings:close");
    expect(order).toContain("win:settings:delay");
  });

  it("omits the incoming-rate readout, which cannot be activated", () => {
    // It is a <span>. Landing on it is a dead stop with no pointer to escape from.
    expect(navOrder({ ...base, settingsOpen: true })).not.toContain("win:settings:rate");
  });

  it("still yields to the palette and to a passive client", () => {
    expect(navOrder({ ...base, settingsOpen: true, paletteOpen: true })).toContain("palette:close");
    expect(navOrder({ ...base, settingsOpen: true, active: false })).toEqual(["claim"]);
  });
});

it("never walks the D-pad onto a row that does not render on glasses", () => {
  // SETTINGS_ROWS drives BOTH the panel renderer and this order. A row hidden by CSS alone would
  // still emit its nav id here, where glasses-nav's querySelector finds nothing and the D-pad
  // silently stops — exactly the win:back / win:minimize / win:close gap AGENTS.md records.
  const order = navOrder({ ...base, settingsOpen: true });
  const ids = visibleSettingsRows("glasses").filter((r) => r.focusable).map((r) => `win:settings:${r.key}`);
  for (const id of order.filter((i) => i.startsWith("win:settings:") && i !== "win:settings:close")) {
    expect(ids).toContain(id);
  }
  expect(order).not.toContain("win:settings:pointer");
});

describe("homeNavOrder — the dashboard (no session)", () => {
  const header = ["home:devices", "home:settings", "profile"];
  const devicesPage = ["home:input", "home:connect", "home:refresh", "home:add-device", "device:a", "device:b"];

  it("is the VISUAL cycle, entered at the first Mac — a rotation, never a reordering", () => {
    const order = homeNavOrder({ session: false, modal: null, header, page: devicesPage });
    expect(order).toEqual(["device:a", "device:b", "home:devices", "home:settings", "profile",
                           "home:input", "home:connect", "home:refresh", "home:add-device"]);
    // The cycle is unchanged: rotated back to the header it is exactly the visual order.
    const at = order.indexOf("home:devices");
    expect([...order.slice(at), ...order.slice(0, at)]).toEqual([...header, ...devicesPage]);
    expect(navStep(order, null, 1)).toBe("device:a");
  });

  it("with no Mac listed, it is entered at the page's first control", () => {
    const page = ["home:input", "home:connect", "home:add-device", "home:action:sign-in"];
    const order = homeNavOrder({ session: false, modal: null, header, page });
    expect(order).toEqual([...page, ...header]);
    expect(navStep(order, null, 1)).toBe("home:input");
  });

  it("an open modal is a TRAP: only its own controls", () => {
    expect(homeNavOrder({ session: false, modal: ["add-device:close"], header, page: devicesPage }))
      .toEqual(["add-device:close"]);
  });

  it("a live session covers the dashboard: nothing behind it is reachable", () => {
    expect(homeNavOrder({ session: true, modal: null, header, page: devicesPage })).toEqual([]);
    expect(homeNavOrder({ session: true, modal: ["add-device:close"], header, page: devicesPage })).toEqual([]);
  });

  it("an empty page leaves the header, and nothing at all leaves nothing", () => {
    expect(homeNavOrder({ session: false, modal: null, header, page: [] })).toEqual(header);
    expect(homeNavOrder({ session: false, modal: null, header: [], page: [] })).toEqual([]);
  });
});
