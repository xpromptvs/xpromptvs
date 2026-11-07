import { describe, it, expect } from "vitest";
import { installDebugHook } from "../src/lib/debug";

describe("installDebugHook", () => {
  it("exposes window.__rdev reflecting live pc/channel state", () => {
    const pc = { connectionState: "connecting" as RTCPeerConnectionState };
    const channels: Record<string, { readyState: RTCDataChannelState }> = {};

    const dbg = installDebugHook({
      role: "client",
      pc,
      getChannels: () => channels as never,
    });

    // Exposed globally and returned.
    expect((globalThis as unknown as { __rdev: unknown }).__rdev).toBe(dbg);
    expect(dbg.role).toBe("client");

    // Live connection state (getter, not snapshot).
    expect(dbg.connectionState).toBe("connecting");
    pc.connectionState = "connected";
    expect(dbg.connectionState).toBe("connected");

    // Only present channels appear.
    expect(dbg.channelStates).toEqual({});
    channels.terminal = { readyState: "open" };
    expect(dbg.channelStates).toEqual({ terminal: "open" });

    // inputLog is a live array.
    dbg.inputLog.push({ t: "touch" });
    expect(dbg.inputLog).toHaveLength(1);
  });

  it("publish: false returns the hook WITHOUT assigning window.__rdev (the controller's getter owns it)", () => {
    delete (globalThis as { __rdev?: unknown }).__rdev;
    const dbg = installDebugHook({ role: "client", pc: { connectionState: "new" }, getChannels: () => ({}), publish: false });
    expect(dbg.role).toBe("client");
    expect((globalThis as { __rdev?: unknown }).__rdev).toBeUndefined();
  });
});
