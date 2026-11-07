# Vendored Noise core

The files here except xxpsk3.ts are derived from @chainsafe/libp2p-noise 17.0.0, copyright ChainSafe Systems, licensed Apache-2.0 OR MIT. The [upstream MIT license](../../../licenses/ChainSafe-Noise-MIT.txt) is included and each file retains its attribution and modification header. Upstream source: https://github.com/ChainSafe/js-libp2p-noise/tree/v17.0.0.

The core handshake state is vendored because the upstream package does not export these internals independently of its libp2p entry point. xxpsk3.ts adds the project's PSK handshake pattern and is original project code. Protocol byte encodings and hash/signature behavior must remain stable.

Dependency updates do not automatically update this vendored code. Review upstream security fixes and run protocol/test/noise-vectors.test.ts against the published protocol/fixtures/noise-vectors.json vectors whenever changing it. The native Rust implementation checks the same vectors.
