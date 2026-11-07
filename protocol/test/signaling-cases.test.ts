import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import Ajv from "ajv";
import { expect, test } from "vitest";

interface Case { name: string; msg: unknown; valid: boolean }

function load<T>(rel: string): T {
  return JSON.parse(readFileSync(fileURLToPath(new URL(rel, import.meta.url)), "utf8")) as T;
}

const schema = load<object>("../schema/signaling.schema.json");
const cases = load<Case[]>("../fixtures/signaling-cases.json");

test("battery has both valid and invalid cases", () => {
  expect(cases.some((c) => c.valid)).toBe(true);
  expect(cases.some((c) => !c.valid)).toBe(true);
});

test("every battery case's valid flag matches the schema verdict", () => {
  const validate = new Ajv({ allErrors: true }).compile(schema);
  for (const c of cases) {
    expect(validate(c.msg), `${c.name} expected valid=${c.valid}`).toBe(c.valid);
  }
});
