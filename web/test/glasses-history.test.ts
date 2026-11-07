import { describe, expect, it } from "vitest";
import { screenFromHistory, pushScreen } from "../src/client/glasses-history";

describe("screenFromHistory", () => {
  it("reads a screen back out of a popstate state object", () => {
    expect(screenFromHistory({ rdevScreen: "terminal" })).toBe("terminal");
    expect(screenFromHistory({ rdevScreen: "window" })).toBe("window");
    expect(screenFromHistory({ rdevScreen: "sources" })).toBe("sources");
  });
  it("returns null for anything it does not recognise", () => {
    expect(screenFromHistory(null)).toBeNull();
    expect(screenFromHistory(undefined)).toBeNull();
    expect(screenFromHistory({})).toBeNull();
    expect(screenFromHistory({ rdevScreen: "banana" })).toBeNull();
    expect(screenFromHistory("terminal")).toBeNull();
  });
  it("ignores a foreign history entry rather than adopting it", () => {
    // Another feature (or the browser) may own an entry; misreading one would jump the wearer to a
    // screen nothing asked for.
    expect(screenFromHistory({ someoneElse: "window" })).toBeNull();
  });

  it("with a generation, adopts only THAT session's entries — never an earlier session's", () => {
    expect(screenFromHistory({ rdevScreen: "terminal", rdevSession: 2 }, 2)).toBe("terminal");
    expect(screenFromHistory({ rdevScreen: "terminal", rdevSession: 1 }, 2)).toBeNull();
    expect(screenFromHistory({ rdevScreen: "terminal" }, 2)).toBeNull();
  });

  it("without a generation it reads the screen as before", () => {
    expect(screenFromHistory({ rdevScreen: "window", rdevSession: 7 })).toBe("window");
  });
});

describe("pushScreen", () => {
  it("pushes when the screen actually changes", () => {
    expect(pushScreen("window", "terminal")).toBe(true);
  });
  it("does NOT push a repeat — back would then need two presses to do anything", () => {
    expect(pushScreen("window", "window")).toBe(false);
  });
  it("pushes the first screen of the session", () => {
    expect(pushScreen("terminal", null)).toBe(true);
  });
});
