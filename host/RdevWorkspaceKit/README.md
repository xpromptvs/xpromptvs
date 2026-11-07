# Experimental workspace placement adapter

**Application capture is parked and disabled in the product as of 2026-10-30.** This adapter remains
for research and recovery. See `docs/experiments/2026-10-25-app-workspace/parking-report.md` before
any attempt to re-enable the feature. The API below describes the retained experiment.

`RWKWorkspace` owns one 1280×800 virtual display and retained live AX references.
It is deliberately restricted to macOS 27 for the first Chromium product test.
On a headless Mac, WindowServer's temporary fallback disappears when the first virtual display
is created. The adapter recognizes the measured fallback-only vendor/model pair and first retains
a Home display at that screen's size. Apps then has a separate return desktop. Home survives
Restore All for this owner’s lifetime; normal quit restores placements before teardown releases
Home and WindowServer recreates its fallback. Other display topologies get no extra Home display.
No application is launched; application identity is a PID, kernel process start timestamp,
and bundle identifier. The host itself and non-regular applications are refused.

Use one serial **background** queue for every call, including property reads. The adapter
uses bounded AX messaging timeouts and synchronous placement/readback. Physical screen work
areas are read on the main queue, so never block main waiting for this queue.

```swift
let workspace = try RWKWorkspace(journalURL: journalURL)
let apps = RWKWorkspace.runningApplications()
try workspace.addApplication(apps[0]) // creates display if necessary
let displayID = workspace.displayID
try workspace.reconcile() // coordinator calls periodically, e.g. once a second
try workspace.removeApplication(apps[0])
try workspace.restoreAll() // releases display only after restoration is accounted for
```

Use a persistent, app-owned journal URL. The journal is atomically written before every
mutation, and contains process identities and geometry, never titles or document contents.
Retain the adapter on a failed removal or close and expose Retry Restore. Never simply drop
it after a restoration failure: destroying the owner releases its virtual display.
`removeApplication` stops reconciliation for that app even when restoration needs retry.
`restoreAll` stops all reconciliation and retains its display on failure. Closing the source
must wait for that method to succeed; normal shutdown must do the same within its deadline.

The initial add preflights all ordinary windows before moving any. Each move has readback;
a failed move rolls back the entire new subset, including a partially changed failing window.
Only standard, non-minimized, non-fullscreen, on-screen windows with settable position and
size are supported. An app with no eligible windows or more than 32 AX windows is refused.
Sheets and dialogs are left attached to their native parents; helpers and other Spaces are
not migrated. Future ordinary windows are discovered by caller-scheduled reconciliation.
Windows born in the workspace receive a physical-display return position based on the app's
first retained placement record. Closed windows are accounted for without recreation.
Original geometry is restored when its display remains online; otherwise it is clamped to a
physical screen's visible bounds.

Cold recovery intentionally fails closed. An unresolved on-disk journal prevents constructing
a new adapter. A disk window ID cannot reconstruct a retained AX reference safely. The caller
must show the error and direct manual window restoration before explicitly archiving the old
journal; do not delete that journal automatically. This is an experimental limitation, not
crash-recovery support.

GUI-free validation:

```
bazelisk test //host/RdevWorkspaceKit:RdevWorkspaceKitTests --test_output=errors
```

These tests cover process identity requirements, fallback bounds, and refusal of unresolved or
malformed cold journals. They do not establish live arbitrary-app movement, fullscreen/Space
behavior, private-display support, or actual restoration after a host crash. Product live testing
must separately verify real-app placement/readback, partial failure, new windows, and restoration.
