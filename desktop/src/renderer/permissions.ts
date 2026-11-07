/// The one branch behind the permission row's button, kept out of the DOM glue so it can be
/// falsified without a renderer. `main.ts` imports it; `test/permissions.test.js` drives it.

export type PermissionAction = "grant" | "settings";

/**
 * What a MISSING permission's button should do.
 *
 * macOS shows each permission prompt once per app signature and never again, so the button is only
 * worth offering as "Grant" until this run has spent that one ask. After that the sole remaining
 * route is System Settings — and it must be offered, because there is no way to tell "declined"
 * from "asked and not yet answered": `CGPreflightScreenCaptureAccess` and `AXIsProcessTrusted` are
 * both false for either. Main remembers what it asked for; this decides what to draw.
 *
 * ABSENT MEANS SPENT, deliberately. `asked` arrives from main's `app:state`, and an older main
 * that does not send it leaves the row exactly as it behaved before this existed — a plain
 * Settings link. The failure mode of the other default is a Grant button that silently does
 * nothing, which is the specific thing this design exists to avoid.
 */
export function permissionRowAction(asked: boolean | undefined): PermissionAction {
  return asked === false ? "grant" : "settings";
}

/** The button's label. One place, so the label can never disagree with what the click does. */
export function permissionRowLabel(action: PermissionAction): string {
  return action === "grant" ? "Grant" : "Open Settings";
}
