import { describe, expect, it } from "vitest";
import { simActionOf, simMenuItems, simOfflineText } from "../src/client/sim-menu";

describe("the simulator tab menu", () => {
  it("offers the buttons, rotation, shake and Shut Down while booted", () => {
    expect(simMenuItems("booted").map((i) => i.label)).toEqual([
      "Home", "App Switcher", "Lock", "Rotate Left", "Rotate Right", "Shake", "Volume Up", "Volume Down", "Siri",
      "Shut Down",
    ]);
  });
  it("offers only Boot while off, and nothing while it changes", () => {
    expect(simMenuItems("shutdown").map((i) => i.label)).toEqual(["Boot"]);
    expect(simMenuItems("booting")).toEqual([]);
    expect(simMenuItems("shutting-down")).toEqual([]);
    expect(simMenuItems(undefined).map((i) => i.label)).toEqual(["Boot"]);
  });
  it("maps an item back to its wire action, and nothing else", () => {
    expect(simMenuItems("booted").map((i) => simActionOf(i.action))).toEqual([
      "home", "app-switcher", "lock", "rotate-left", "rotate-right", "shake", "volume-up", "volume-down", "siri", "shutdown",
    ]);
    expect(simActionOf("kill-tmux")).toBeNull();
    expect(simActionOf("sim-explode")).toBeNull();
  });
  it("says why the picture is missing", () => {
    expect(simOfflineText("shutdown")).toBe("Shut down");
    expect(simOfflineText("shutting-down")).toBe("Shutting down…");
    expect(simOfflineText("booting")).toBe("Booting…");
    expect(simOfflineText("booted")).toBe("Booting…");   // booted, picture not up yet (~20 s)
  });
});
