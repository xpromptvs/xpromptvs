import { describe, expect, it } from "vitest";
import { parseSourceList, parseSourceStatus, sourceStateLabel } from "../src/client/source-picker";
import { tabKind } from "../src/client/tab-order";

const UDID = "9B45C574-451C-475D-8498-66BD68AEE17D";

describe("simulator sources", () => {
  it("reads simState off a listed simulator", () => {
    const msg = parseSourceList({ t: "source-list", sources: [
      { id: `sim:${UDID}`, kind: "sim", name: "iPhone 18 Pro (iOS 27.0)", inputCapable: true, running: false,
        w: 402, h: 874, simState: "shutdown" },
    ] });
    expect(msg?.sources[0]?.simState).toBe("shutdown");
  });

  it("rejects a simState the protocol does not have", () => {
    expect(parseSourceList({ t: "source-list", sources: [
      { id: `sim:${UDID}`, kind: "sim", name: "x", inputCapable: true, running: false, simState: "asleep" },
    ] })).toBeNull();
  });

  it("reads simState off a status", () => {
    const s = parseSourceStatus({ t: "source-status", statuses: [{ id: `sim:${UDID}`, live: false, simState: "booting" }] });
    expect(s?.statuses[0]?.simState).toBe("booting");
  });

  it("labels a simulator tile by its state", () => {
    const row = { id: `sim:${UDID}`, kind: "sim", name: "x", inputCapable: true, current: false };
    expect(sourceStateLabel({ ...row, running: false, simState: "shutdown" })).toBe("shut down");
    expect(sourceStateLabel({ ...row, running: false, simState: "booting" })).toBe("booting…");
    expect(sourceStateLabel({ ...row, running: false, simState: "shutting-down" })).toBe("shutting down…");
    expect(sourceStateLabel({ ...row, running: true, simState: "booted" })).toBeNull();
  });

  it("makes a simulator a window tab, in its canonical spelling only", () => {
    expect(tabKind(`sim:${UDID}`)).toBe("window");
    expect(tabKind(`sim:${UDID.toLowerCase()}`)).toBeNull();
    expect(tabKind("sim:abc")).toBeNull();
  });
});
