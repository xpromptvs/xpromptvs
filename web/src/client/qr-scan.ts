/**
 * What the sheet is doing.
 *
 * **`insecure` is separate from `no-camera` on purpose**: one is a property of the page's ORIGIN and
 * is fixed by using a different URL, the other is the device. Collapsing them would tell someone on
 * a LAN dev origin to go buy a webcam.
 */
export type ScanState =
  | { kind: "insecure" }
  | { kind: "no-camera" }
  | { kind: "asking" }
  | { kind: "refused" }
  | { kind: "scanning" }
  | { kind: "foreign"; origin: string }
  | { kind: "failed"; reason: string };

export interface ScanView {
  heading: string;
  body: string;
  actions: { id: string; label: string }[];
  /** Whether the `<video>` is shown. False for every state that cannot produce a frame. */
  showVideo: boolean;
}

const CLOSE = [{ id: "close", label: "Close" }];

/**
 * **PURE, because the wording is most of what this surface is** — and because a camera, a permission
 * prompt and a physical QR are the three things a unit test cannot have.
 */
export function scannerModel (state: ScanState): ScanView {
  switch (state.kind) {
    case "insecure":
      return {
        heading: "Scanning needs a secure page",
        body: "A browser only gives the camera to a page served over HTTPS or from localhost. "
            + "This page is neither, so type or paste the code instead.",
        actions: CLOSE, showVideo: false,
      };
    case "no-camera":
      return {
        heading: "No camera here",
        body: "This device has no camera the browser will offer. Type or paste the code instead.",
        actions: CLOSE, showVideo: false,
      };
    case "asking":
      return {
        heading: "Allow the camera",
        body: "Point it at the code on the other screen.",
        actions: CLOSE, showVideo: false,
      };
    case "refused":
      // Not "denied" and not "error": a person who said no has not broken anything, and the same
      // NotAllowedError arrives whether they refused or the prompt was dismissed.
      return {
        heading: "The camera stayed closed",
        body: "Nothing was scanned. Allow camera access for this site and try again, or type the "
            + "code instead.",
        actions: [{ id: "retry", label: "Try again" }, ...CLOSE], showVideo: false,
      };
    case "scanning":
      return {
        heading: "Point at the code",
        body: "Hold steady — it reads by itself.",
        actions: CLOSE, showVideo: true,
      };
    case "foreign":
      // **NOTHING WAS OPENED, and it says so.** The whole point of the origin rule is that the
      // refusal is the end of it, so the sentence has to close the loop rather than warn vaguely.
      return {
        heading: "That code is for a different site",
        body: `It points at ${state.origin}, which is not for this app. Nothing was opened.`,
        actions: [{ id: "retry", label: "Scan again" }, ...CLOSE], showVideo: false,
      };
    case "failed":
      return {
        heading: "That did not work",
        body: `The camera stopped (${state.reason}).`,
        actions: [{ id: "retry", label: "Try again" }, ...CLOSE], showVideo: false,
      };
  }
}

import { createDecoder } from "./qr-decode";
import { routeScanned, type Scanned } from "./qr-route";

/**
 * **The sheet. It owns the camera and nothing else.**
 *
 * Every decision belongs to `scannerModel` or `routeScanned`; this carries frames between them and
 * puts the result on screen. `getUserMedia` and `isSecure` are injected so the whole pipeline is
 * drivable from a check with a canvas stream and no device — production passes neither.
 */
export function mountScanner (opts: {
  origin: string;
  onScanned: (s: Scanned) => void;
  getUserMedia?: (c: MediaStreamConstraints) => Promise<MediaStream>;
  isSecure?: boolean;
}): { close: () => void } {
  const secure = opts.isSecure ?? window.isSecureContext;
  const media = opts.getUserMedia
    ?? ((c: MediaStreamConstraints) => navigator.mediaDevices.getUserMedia(c));

  const sheet = document.createElement("div");
  sheet.id = "qr-sheet";
  sheet.className = "qr-sheet";
  const heading = document.createElement("h2");
  const body = document.createElement("p");
  const video = document.createElement("video");
  video.id = "qr-video";
  // **iOS NEEDS ALL THREE**: muted and playsinline or it refuses to play inline at all, and a user
  // gesture to open the camera — which the Scan button is.
  video.muted = true;
  video.playsInline = true;
  video.setAttribute("playsinline", "");
  const actions = document.createElement("div");
  actions.className = "qr-sheet-actions";
  sheet.append(heading, body, video, actions);
  document.body.appendChild(sheet);

  let stream: MediaStream | null = null;
  let stopped = false;

  const stopCamera = (): void => {
    stream?.getTracks().forEach((t) => t.stop());
    stream = null;
  };

  const close = (): void => {
    stopped = true;
    stopCamera();
    sheet.remove();
  };

  const render = (state: ScanState): void => {
    const view = scannerModel(state);
    heading.textContent = view.heading;
    body.textContent = view.body;
    video.hidden = !view.showVideo;
    actions.replaceChildren(...view.actions.map((a) => {
      const b = document.createElement("button");
      b.id = `qr-${a.id}`;
      b.dataset.navId = `qr:${a.id}`;       // the sheet is a modal the glasses D-pad walks
      b.textContent = a.label;
      b.addEventListener("click", () => { if (a.id === "close") close(); else void run(); });
      return b;
    }));
  };

  async function run (): Promise<void> {
    stopped = false;
    if (!secure) { render({ kind: "insecure" }); return; }
    if (!opts.getUserMedia && !navigator.mediaDevices?.getUserMedia) {
      render({ kind: "no-camera" }); return;
    }
    render({ kind: "asking" });
    try {
      stream = await media({ video: { facingMode: "environment" }, audio: false });
    } catch (e) {
      // **A REFUSED CAMERA IS A DECISION, NOT A FAULT**, and `NotAllowedError` is what both a
      // refusal and a dismissal produce — the same indistinguishability a passkey prompt has.
      const name = (e as { name?: string }).name ?? "";
      render(name === "NotAllowedError"
        ? { kind: "refused" }
        : { kind: "failed", reason: name || "unavailable" });
      return;
    }
    video.srcObject = stream;
    await video.play().catch(() => {});
    render({ kind: "scanning" });

    const decoder = await createDecoder();
    while (!stopped) {
      const text = await decoder.detect(video);
      if (text) {
        const routed = await routeScanned(text, opts.origin);
        if (routed.kind === "foreign") {
          // **SHOWN AND NOT ACTED ON.** The whole point of the origin rule is that nothing opens;
          // the camera stops so it cannot re-read the same sticker a frame later.
          stopCamera();
          render(routed);
          return;
        }
        if (routed.kind !== "unknown") { close(); opts.onScanned(routed); return; }
      }
      await new Promise((r) => requestAnimationFrame(() => r(null)));
    }
  }

  void run();
  return { close };
}
