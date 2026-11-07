import { decodeJson, encodeJson } from "../lib/codec";
import { PeerSession } from "../lib/peer";
import { SignalingClient } from "../lib/signaling";
import { SecureSignalling } from "../client/e2e-signalling";
import { ClientE2EIdentity } from "../client/e2e-identity";
import { IndexedDBInstallationBackend } from "../lib/installation-idb";
import { E2EHostGate, openPairingWindow } from "@rdev/protocol";
import { startTestPattern } from "./testpattern";
import { installDebugHook } from "../lib/debug";
import type { Channels } from "../lib/peer";

const base = location.origin.replace(/^http/, "ws");
const pairingEl = document.getElementById("pairing")!;
const logEl = document.getElementById("log")!;
const patternCanvas = document.getElementById("pattern") as HTMLCanvasElement;
const log = (s: string) => { logEl.textContent += s + "\n"; };

// §9.1: THE ISSUER GENERATES. One seed becomes `code`, `token` and `psk`; only the two public values
// are registered. The same three steps `PairingWindowOpener` takes on the Mac.
const opened = await openPairingWindow(location.origin);
if (!opened.ok) throw new Error(`could not open a pairing window: ${opened.failure}`);
const { code, token } = opened.value.material;
// **THE CARRIER IS PRINTED, THE SEED IS NOT SENT.** A dev harness that put it in the query would
// teach the wrong shape to everything that copies from it.
pairingEl.textContent = `code: ${code}  token: ${token}  pairing: ${opened.value.carrier}`;

const stream = startTestPattern(patternCanvas);
const socket = new WebSocket(`${base}/session/${code}`);
const pc = new RTCPeerConnection();
let channels: Partial<Channels> = {};
let tracksAdded = false;
const dbg = installDebugHook({ role: "host", pc, getChannels: () => channels });
let signaling: SignalingClient;
let currentPeerId: string | undefined;

const peer = new PeerSession(pc, "host", {
  onLocalDescription: (d) => {
    if (!d.sdp) return;
    const sdp = d.sdp;
    sendSignalling({ t: "offer", sdp });
  },
  onIceCandidate: (c) => {
    sendSignalling({ t: "ice", cand: c.toJSON() as Record<string, unknown> });
  },
  onChannels: ({ terminal, input, control, bulk }) => {
    channels = { terminal, input, control, bulk };
    if (!tracksAdded) {
      for (const track of stream.getVideoTracks()) peer.addTrack(track, stream);
      tracksAdded = true;
    }
    // NO TERMINAL: this page sends nothing on `terminal`. The terminal is the Swift host's (its live
    // wire of per-tab snapshots and DEFLATE streams), and it is covered by the checks that run against
    // that host; the retired cell-frame emitter that lived here tested a renderer that no longer exists.
    input.binaryType = "arraybuffer";
    input.addEventListener("message", (e) => {
      const msg = decodeJson<{ t: string }>(new Uint8Array(e.data as ArrayBuffer));
      dbg.inputLog.push(msg);
      log(`input: ${JSON.stringify(msg)}`);
    });
    control.binaryType = "arraybuffer";
    // Announce control-state, exactly as the real host does on control-open (ChannelHub.controlStateJSON).
    // Without it the client's SessionControl never marks itself active, and `reconcileSimVisibility` would
    // hide #windows the moment anything triggers it. That used to be invisible ONLY because nothing on this
    // path ever triggered a reconcile — i.e. the harness was silently depending on the bug that syncVideo()
    // now fixes. A harness that does not speak the host's protocol is a harness that tests the wrong thing.
    control.addEventListener("open", () => {
      control.send(encodeJson({ t: "control-state", active: true, clients: 1 }) as Uint8Array<ArrayBuffer>);
    });
  },
});

/**
 * §11. Signalling exists only inside it.
 *
 * **This page is a RESPONDER**, so it runs `E2EHostGate`, not the client's. Its identity lives under
 * its own IndexedDB keys because the client is on the SAME ORIGIN: two peers sharing one
 * installation would present one descriptor from both ends, and §11.1's expected-peer check — and
 * Noise itself — would be checking a device against itself.
 */
let secure: SecureSignalling | null = null;
/** §11.2: a peer that has not opened the gate is not a peer yet, so the offer waits. */
let admitted = false;

function admit(peerId: string): void {
  if (admitted) return;
  admitted = true;
  currentPeerId = peerId;
  log("client authenticated → offering");
  void peer.startOffer();
}

/**
 * **Built BEFORE the socket, not when a peer joins.** The initiator speaks first, so its opening
 * envelope can arrive the instant this page says hello — and a gate still being loaded out of
 * IndexedDB would drop it, leaving both ends waiting on each other with nothing in either log.
 */
async function openSecure(): Promise<void> {
  const identity = new ClientE2EIdentity(
    new IndexedDBInstallationBackend("host-v1"),
    new IndexedDBInstallationBackend("host-trust-v1"));
  const config = await identity.hostGateConfig(code);
  if (!config) { log("e2e: this peer has no encryption identity"); return; }
  secure = new SecureSignalling(new E2EHostGate(config), {
    // The peer is ROUTING, and a host has more than one to choose from — without it the relay
    // drops the envelope and both ends wait on each other.
    sendE2E: (ct, mode) => { signaling.sendE2E(ct, mode, currentPeerId); },
    deliver: (message) => {
      const m = message as { t?: string; sdp?: string; cand?: Record<string, unknown> };
      if (m.t === "answer" && typeof m.sdp === "string") { peer.acceptAnswer(m.sdp); return; }
      if (m.t === "ice" && m.cand) { peer.addIce(m.cand as RTCIceCandidateInit); return; }
      log(`e2e: unhandled inner message "${String(m.t)}"`);
    },
    onClosed: (reason) => { secure = null; admitted = false; log(`e2e: session ended (${reason})`); },
  });
}

// **§11.2: nothing leaves outside the session once there is one.** A refused seal is not a reason to
// send in the clear — that is the whole protocol opted out of by a peer that declined to handshake.
function sendSignalling(message: Record<string, unknown>): void {
  if (!secure || !secure.send(message)) log("e2e: withheld a signalling message");
}

await openSecure();

signaling = new SignalingClient(socket, { role: "host", token, codecs: ["deflate"] }, {
  onWelcome: (turn) => {
    pc.setConfiguration({
      iceServers: [{ urls: turn.urls, username: turn.username, credential: turn.credential }],
    });
    log("welcome; waiting for client");
  },
  onPeerJoined: (peerId) => {
    currentPeerId = peerId;
    // §11.2: a peer that has not opened the gate is not a peer yet, so the offer waits for it.
    log("client joined → waiting for §11");
    if (secure?.maySignal) admit(peerId);
  },
  onE2E: (ct, peerId, mode) => {
    // The envelope names its sender; a host answers the peer it heard from.
    if (peerId) currentPeerId = peerId;
    secure?.receive(ct, mode);
    if (secure?.maySignal && currentPeerId) admit(currentPeerId);
  },
  onPeerLeft: () => { secure?.close(); secure = null; admitted = false; log("client left"); },
  onError: (c, m) => log(`error: ${c} ${m ?? ""}`),
});
