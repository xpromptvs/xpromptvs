import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";
import {
  SocketChannel, SOCKET_HELLO_VERSION, decodeSocketFrame, encodeSocketFrame, encodeSocketHello,
  parseSocketHello, type SocketChannelName,
} from "../src/socket-frame";

// The message-socket transport's frame and hello, against vectors a THIRD implementation produced
// (scripts/gen_socket_frame_fixture.py). RdevCore's SocketFrameTests asserts the same file, so each
// side agrees with something neither wrote.
interface Fixture {
  channels: Record<string, number>; helloVersion: number;
  frames: { name: string; channel: SocketChannelName; payload: string; frame: string }[];
  malformedFrames: { name: string; frame: string }[];
  hellos: { name: string; payload: string; client: string; intent: string }[];
  encodedHellos: { client: string; intent: "connect" | "reconnect"; payload: string }[];
  malformedHellos: { name: string; payload: string }[];
}
const fx = JSON.parse(readFileSync(
  fileURLToPath(new URL("../fixtures/socket-frames.json", import.meta.url)), "utf8")) as Fixture;
const hex = (s: string) => new Uint8Array((s.match(/../g) ?? []).map((b) => parseInt(b, 16)));

test("the fixture and the implementation agree about the channels and the version", () => {
  expect(fx.channels).toEqual(SocketChannel);
  expect(fx.helloVersion).toBe(SOCKET_HELLO_VERSION);
  for (const k of ["frames", "malformedFrames", "hellos", "encodedHellos", "malformedHellos"] as const) {
    expect(fx[k].length, `an empty ${k} would pass every assertion below`).toBeGreaterThan(0);
  }
});

describe("frames", () => {
  for (const f of fx.frames) {
    test(f.name, () => {
      expect(encodeSocketFrame(f.channel, hex(f.payload))).toEqual(hex(f.frame));
      expect(decodeSocketFrame(hex(f.frame))).toEqual({ channel: f.channel, payload: hex(f.payload) });
    });
  }
  for (const f of fx.malformedFrames) {
    test(`refuses: ${f.name}`, () => { expect(decodeSocketFrame(hex(f.frame))).toBeNull(); });
  }
});

describe("hello", () => {
  for (const h of fx.hellos) {
    test(h.name, () => { expect(parseSocketHello(hex(h.payload))).toEqual({ client: h.client, intent: h.intent }); });
  }
  for (const h of fx.encodedHellos) {
    test(`encodes ${h.client} ${h.intent}`, () => {
      expect(encodeSocketHello({ client: h.client, intent: h.intent })).toEqual(hex(h.payload));
    });
  }
  for (const h of fx.malformedHellos) {
    test(`refuses: ${h.name}`, () => { expect(parseSocketHello(hex(h.payload))).toBeNull(); });
  }
});
