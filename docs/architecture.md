# Architecture and security

The Mac app links its host in process and serves its bundled dashboard and client through separate WKWebView origins. app/ owns native windows and bridges; desktop/ builds the dashboard; web/ implements the client; host/ owns terminals, capture, input and transport; protocol/ defines shared wire encodings and fixtures.

The hosted service coordinates pairing and connection setup. Peers establish WebRTC media/data transport, with TURN fallback where required. Signaling carries authenticated encrypted records; device grants and root identities are verified by endpoints. The service is not trusted to substitute a media identity. Keep verification, authority checks and revocation behavior intact when modifying clients.

Host state owns tabs, focus, selection and view order. Reconnecting clients render that state. Native source windows belong to a single admitted client generation; stale input and asynchronous callbacks must not affect a replacement owner. The host's own windows are excluded from capture and subscriptions.

Terminals run through PTYs and a server-side terminal model; cell-grid updates and shared fixtures preserve truecolor and Unicode behavior. Persistent tabs restore working directories and tmux attachments. Capture uses ScreenCaptureKit for windows/desktops and a separate framebuffer/HID path for simulators. Encoders are shared through the imported LLV core and Pion C ABI; AV1/libaom and VideoToolbox codecs retain their pinned build configuration. Remote source audio and input remain source-bound.

The publication configuration is defined in config/product-features.json and checked across UI/native assembly. Disabled integrations can remain in source for shared-code compatibility but have no entry points, restored sessions or host executors in this edition. Application-workspace capture remains disabled.
