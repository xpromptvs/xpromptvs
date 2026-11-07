# Testing

Install locked dependencies as described in README.md. Fast suites:

```sh
npm --prefix protocol test
npm --prefix web test
node --test scripts/test/product-features.test.mjs
bazelisk test //host/RdevCore:RdevCoreTests //app:ShellstormCoreTests
```

The web suite explicitly uses the development feature profile to test retained source modules; the normal app build always uses the publication profile. Publication UI tests separately assert unavailable controls and overrides. Native host tests can be run with `bazelisk test --//config:profile=development //host/RdevHostKit:RdevHostKitTests`; this includes environment-sensitive tmux fixtures. A tmux/utf8proc version mismatch is not a reason to regenerate measured fixtures without reviewing their fidelity.

Standalone browser checks and selected harness tools are retained where they test product behavior without the excluded service source. A service integration check requires an isolated externally supplied service and separate test identities; never use production for destructive tests. Source-publication tooling remains in the private development repository.

Manual verification includes code-based enrollment, pairing/reconnect, terminal persistence, real remote window/desktop/simulator input and video, Screen Recording/Accessibility permission behavior, and physical trackpad/touch scrolling. Deterministic browser scroll models do not prove native gesture behavior. Build/check scripts must use separate output paths and profiles and leave the installed work app alone.

Native publication refusals can be checked with `bazelisk test --//config:profile=publication //host/RdevHostKit:RdevHostKitTests --test_filter=testUnavailableAgentsReplyToDriverWithoutAnExecutor`.

For standalone browser checks, install `npm --prefix e2e ci` and the Playwright Chromium browser, then run `npm --prefix web run dev` in another terminal. `npm --prefix e2e run test:windows` drive the built session UI against that local server without deploying a service. `test:prediction` launches only the source-edition app through its isolated automation profile; set RDEV_APP to its executable if you used a different output directory.

Historical inline-key-strip and design-workbench browser checks are excluded: the current keyboard drawer and embedded session boundaries have unit coverage in the retained web suite. Fullscreen, native gestures and permissions still need the manual verification described above.
