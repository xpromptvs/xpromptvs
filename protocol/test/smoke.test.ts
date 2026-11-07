import { expect, test } from "vitest";
import { PROTOCOL_VERSION } from "../src/index";

test("package exposes a protocol version", () => {
  expect(PROTOCOL_VERSION).toBe(1);
});
