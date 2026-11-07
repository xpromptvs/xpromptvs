import { describe, it, expect } from "vitest";
import { buildTagFrom } from "./build-tag";

describe("buildTagFrom", () => {
  // THE HASHED FILENAME IS THE BUILD IDENTITY. It must come back in the same shape it has in
  // `web/dist/assets`, or comparing the two by eye — the whole point — does not work.
  it("takes the hashed bundle name out of a served URL", () => {
    expect(buildTagFrom("https://example.workers.dev/assets/client-CfqeF5hC.js"))
      .toBe("client-CfqeF5hC.js");
  });

  it("handles the app:// origin the native shell serves from", () => {
    expect(buildTagFrom("app://client/assets/client-BT4Nr1wd.js")).toBe("client-BT4Nr1wd.js");
  });

  // A QUERY OR FRAGMENT MUST NOT REACH THE TAG. Either would make the same build report two
  // different identities and defeat the comparison.
  it("drops a query string", () => {
    expect(buildTagFrom("https://x/assets/client-abc.js?v=2")).toBe("client-abc.js");
  });

  it("drops a fragment", () => {
    expect(buildTagFrom("https://x/assets/client-abc.js#map")).toBe("client-abc.js");
  });

  it("drops a fragment that itself contains a slash", () => {
    expect(buildTagFrom("https://x/assets/client-abc.js#/a/b")).toBe("client-abc.js");
  });

  it("passes a bare filename through", () => {
    expect(buildTagFrom("client-abc.js")).toBe("client-abc.js");
  });

  // NEVER EMPTY. An empty tag in the host log reads as a missing field rather than as an answer,
  // and this line exists precisely to remove that ambiguity.
  it("says unknown rather than nothing when there is no filename", () => {
    expect(buildTagFrom("https://example.com/")).toBe("unknown");
    expect(buildTagFrom("")).toBe("unknown");
  });
});
