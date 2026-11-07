import { describe, expect, it } from "vitest";
import { SessionSkeleton } from "../src/client/session-skeleton";

describe("SessionSkeleton — the tab bar's placeholders while a session loads", () => {
  it("shows from the start, and the host's list takes it away", () => {
    document.body.innerHTML = `<div id="t" class="hidden"></div>`;
    const tabs = document.getElementById("t")!;
    const skeleton = new SessionSkeleton(tabs);
    expect(tabs.classList.contains("hidden")).toBe(false);
    skeleton.listed();
    expect(tabs.classList.contains("hidden")).toBe(true);
  });

  /// Asked: "When opening a remote device, don't display skeleton in the terminal".
  it("the terminal area has none: the session's markup carries no stage skeleton", async () => {
    const html = (await import("../src/client/instance/session.html?raw")).default as string;
    expect(html).toContain('id="tab-skeleton"');
    expect(html).not.toContain("session-skeleton\"");
    expect(html).not.toContain('id="session-skeleton"');
  });
});
