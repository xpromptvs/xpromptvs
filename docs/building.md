# Building the Mac app

Use an Apple Silicon Mac running macOS 26 or later, a compatible Xcode/command-line tools installation, Node.js 20.19+, npm, Bazelisk, and CMake. The repository pins Bazel, Go, Rust and native dependencies. Native builds use Bazel exclusively.

Run the commands in README.md from the repository root. Initialize both codec submodules at their committed revisions; do not substitute branch heads. UI dependencies install from their lockfiles. The default build is a separate, ad-hoc signed local development app. `RDEV_SIGN_IDENTITY` selects an identity in your own keychain; it does not grant access to the official app's provisioning or associated domains.

The native webcredentials entitlement cannot be copied into a fork: Apple checks both provisioning and the service's associated-app list. The default source build does not use the official provisioning profile or associated-domain entitlements. Native passkey creation/sign-in therefore does not work as the official app does. Use Add by code from an already enrolled browser to authorize the source app's own device keys. The service's normal cryptographic verification remains enabled. Independent end-to-end enrollment must be manually verified before a distribution claims service compatibility.

Local app data and identity use ai.xpromptvs.development, separate from the official installation. Auto-updates through official releases are disabled in source builds. To rebuild, choose a fresh output directory with `RDEV_APP_OUT=/absolute/path/to/new-output npm --prefix desktop run build:check`; assembly refuses to overwrite an existing app. Run the generated .app with `open` after reviewing the output path. Do not replace /Applications automatically.

Share this Mac needs Screen Recording for video capture and Accessibility for input injection. Permissions follow the app signature; an ad-hoc rebuild can require granting them again. Terminal-only use does not require video capture permissions. A release-mode local build uses `npm --prefix desktop run package`; it is not a notarized official distribution. Distribution with your own identity requires your own signing/notarization process and distinct branding.

## Official distribution

Ordinary builds remain isolated. The official publisher can select `RDEV_APP_DISTRIBUTION=official` with `RDEV_PRODUCT_PROFILE=publication`, `RDEV_SIGN_IDENTITY`, `RDEV_RELEASE_RECORD`, and a fresh `RDEV_APP_OUT`, then run `npm --prefix desktop run package`. This restores the existing Xpromptvs bundle identity, storage, associated-domain entitlement and updater. It requires the matching Developer ID private key and `rdev-notary` keychain credentials; the public provisioning profile grants no signing authority. Graphical agents and glasses remain disabled. Packaging signs and notarizes both app and DMG and refuses a failed Gatekeeper assessment.
