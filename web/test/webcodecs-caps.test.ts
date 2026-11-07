import { expect, test } from "vitest";
import { parsePayloadTypeMap, webCodecsStringFor } from "../src/lib/webcodecs-caps";

test("H.265 maps to hev1, NOT hvc1 — the transform delivers Annex-B", () => {
  expect(webCodecsStringFor("video/H265")).toMatch(/^hev1\./);
  expect(webCodecsStringFor("video/H265")).not.toMatch(/^hvc1\./);
});

test("H.264 takes its profile from the fmtp profile-level-id, and defaults when absent", () => {
  expect(webCodecsStringFor("video/H264", "packetization-mode=1;profile-level-id=42e01f")).toBe("avc1.42e01f");
  expect(webCodecsStringFor("video/H264")).toBe("avc1.42e01f");
  expect(webCodecsStringFor("video/H264", "profile-level-id=640C1F")).toBe("avc1.640c1f");
});

test("AV1 maps, and a non-media or unknown codec does not", () => {
  expect(webCodecsStringFor("video/AV1")).toMatch(/^av01\./);
  expect(webCodecsStringFor("video/VP8")).toBeNull();
  expect(webCodecsStringFor("video/rtx")).toBeNull();
  expect(webCodecsStringFor("video/flexfec-03")).toBeNull();
});

test("parsePayloadTypeMap reads rdev's three codecs out of a real answer shape", () => {
  const sdp = [
    "m=video 9 UDP/TLS/RTP/SAVPF 45 46 108 109 102 103 47",
    "a=rtpmap:45 AV1/90000",
    "a=rtpmap:46 rtx/90000",
    "a=rtpmap:108 H265/90000",
    "a=fmtp:108 profile-id=1;tier-flag=0;tx-mode=SRST",
    "a=rtpmap:102 H264/90000",
    "a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f",
    "a=rtpmap:47 flexfec-03/90000",
  ].join("\r\n");
  const map = parsePayloadTypeMap(sdp);
  expect(map.get(45)).toMatch(/^av01\./);
  expect(map.get(108)).toMatch(/^hev1\./);
  expect(map.get(102)).toBe("avc1.42e01f");
  // rtx, its partner and FlexFEC are not decodable codecs and must never reach configure().
  expect(map.has(46)).toBe(false);
  expect(map.has(103)).toBe(false);
  expect(map.has(47)).toBe(false);
  expect(map.size).toBe(3);
});

test("an empty or codec-less description yields an empty map rather than throwing", () => {
  expect(parsePayloadTypeMap("").size).toBe(0);
  expect(parsePayloadTypeMap("v=0\r\nm=audio 9 RTP/AVP 111\r\na=rtpmap:111 opus/48000/2").size).toBe(0);
});
