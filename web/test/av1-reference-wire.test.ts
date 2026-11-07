import { expect, test } from "vitest";
import cases from "../../protocol/fixtures/av1-reference.json";
import { parseReferenceMessage } from "../src/shared/av1-reference-wire";
for (const c of cases) test(c.name, () => {
  const parsed = parseReferenceMessage(c.message);
  if (c.valid) expect(parsed).toEqual(c.message);
  else expect(parsed).toBeNull();
});
test("nonobjects cannot become receipts", () => {
  for (const value of [null, [], 1, "receipt"]) expect(parseReferenceMessage(value)).toBeNull();
});
test("binding preserves its negotiated track identity and validates its bounds", () => {
  const message = { t: "av1-ref-bind", source: "win:1", epoch: "e", trackId: "video-generation-2" };
  expect(parseReferenceMessage(message)).toEqual(message);
  for (const trackId of [null, 1, "", "x".repeat(129)]) expect(parseReferenceMessage({ ...message, trackId })).toBeNull();
});
