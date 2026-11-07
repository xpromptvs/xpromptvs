# Xpromptvs maintenance

The native app is Swift/AppKit with a WKWebView client and an in-process host. Bazel is the native build system; npm builds the bundled UI. Read docs/building.md, docs/architecture.md and docs/testing.md before changing those areas.

Keep product-features.json authoritative across native and UI builds. Preserve the terminal-first publication profile and refuse unsupported feature requests on the host. Host session state is authoritative; reconnecting clients render it without replaying local state. Source capture, input focus and native admission must remain ownership-fenced.

Keep dependency lockfiles, source pins and upstream notices. Do not change security checks or signing requirements merely to make local builds pass. Independent builds use their own identity, data and update policy. Never overwrite a person's installed app during automated checks; build into a fresh RDEV_APP_OUT.

Run checks appropriate to a change. Terminal fidelity uses protocol fixtures shared by implementations; preserve their provenance. Tests that post input or require Screen Recording, Accessibility, a physical gesture or a second device need explicit manual verification. Keep fixtures and test outputs distinct.
