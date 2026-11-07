import { expect, test } from "vitest";
import { SignalingClient, type WebSocketLike } from "../src/lib/signaling";
import { LEAVE_CLOSE_CODE } from "@rdev/protocol";

class FakeSocket implements WebSocketLike {
  sent: string[] = [];
  closes: Array<{ code?: number; reason?: string }> = [];
  send(d: string) { this.sent.push(d); }
  close(code?: number, reason?: string) { this.closes.push({ code, reason }); }
  addEventListener(_t: string, _cb: (e: any) => void) {}
}

test("leave() closes with the shared leave code", () => {
  const sock = new FakeSocket();
  const c = new SignalingClient(sock, { role: "client", token: "tok" }, {});
  c.leave();
  expect(sock.closes).toHaveLength(1);
  expect(sock.closes[0]!.code).toBe(LEAVE_CLOSE_CODE);
});

// close() is the ordinary teardown and must stay indistinguishable from a drop, or every
// programmatic disconnect would reap the identity and defeat the grace window.
test("close() does not send a leave code", () => {
  const sock = new FakeSocket();
  const c = new SignalingClient(sock, { role: "client", token: "tok" }, {});
  c.close();
  expect(sock.closes[0]!.code).toBeUndefined();
});

// LOAD-BEARING, and the reason this test exists: the real socket under SignalingClient is a
// ReconnectingSocket, whose close() originally took NO arguments and forwarded none. leave() would
// then have closed with the browser default code, the control plane would have read a deliberate
// departure as a blip, and the whole feature would have been inert — while the test above still
// passed, because it drives a fake. Test the real class, not only the fake.
test("ReconnectingSocket forwards the close code to the underlying socket", async () => {
  const { ReconnectingSocket } = await import("../src/lib/reconnecting-socket");
  const closes: Array<{ code?: number; reason?: string }> = [];
  const inner = {
    send() {},
    close(code?: number, reason?: string) { closes.push({ code, reason }); },
    addEventListener() {},
  };
  const rs = new ReconnectingSocket(() => inner as any);
  rs.close(LEAVE_CLOSE_CODE, "leaving");
  expect(closes).toEqual([{ code: LEAVE_CLOSE_CODE, reason: "leaving" }]);
});
