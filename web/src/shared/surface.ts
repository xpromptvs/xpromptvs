/**
 * **Which of the two dashboards is asking.**
 *
 * The browser client (`#welcome`) and the native app (`app://ui/`) render the same modules out of
 * `web/src/shared/`, and a handful of decisions genuinely differ between them — always because of
 * something a Mac cannot do rather than a style choice. Every one of those is a `Surface` parameter
 * rather than a second copy of the module, so the difference is read side by side:
 *
 * - a browser and a Mac both SIGN IN with a passkey — `navigator.credentials` in one, the platform's
 *   native API in the other since 2026-10-06 — and the sentences name the device (`device-list.ts`,
 *   `e2e-setup.ts`);
 * - signing out deletes that device's keys on both, and the way back differs (`sign-out-dialog.ts`).
 *
 * **`"app-client"` is the app's own CLIENT window** (`app://client/`, `client/welcome.ts`) — the
 * browser client's dashboard, running inside the Mac's app. It runs no ceremony of its own (an
 * `app://` page cannot use `xpromptvs.ai`'s passkeys), so it is offered none; its identity is a SUBORDINATE one
 * the Mac certifies when the window opens (§10.3), so signing it out deletes only the WINDOW's keys
 * and it comes back on its own. Every sentence that is about "this device" says window there.
 */
export type Surface = "browser" | "mac" | "app-client";
