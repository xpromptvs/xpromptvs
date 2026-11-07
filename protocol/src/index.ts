export const PROTOCOL_VERSION = 1;
export * from "./envelope";
export * from "./pairing-seed";
export * from "./rendezvous-seed";
export * from "./e2e-wire";
export * from "./e2e-identity";
export * from "./e2e-certificate";
export * from "./e2e-verify";
export * from "./e2e-session";
export * from "./e2e-signalling-gate";
export * from "./e2e-host-gate";
export * from "./e2e-authorization";
export * from "./e2e-directory";
export * from "./e2e-ice-buffer";
export * from "./device-identity";
export * from "./e2e-enrollment";
export * from "./identity-code";
export * from "./webauthn";
export * from "./e2e-trust-store";
export * from "./e2e-device-label";
export * from "./e2e-host-list";
export * from "./socket-frame";

// The Noise core and the one pattern §11.1 needs that upstream does not implement. Exported
// NARROWLY — `export *` from the vendored module would put CipherState and SymmetricState in the
// client's surface, which are the pieces a caller has no business touching.
export { XXHandshakeState, AbstractHandshakeState } from "./noise/protocol.js";
export { XXpsk3HandshakeState } from "./noise/xxpsk3.js";
export { NoiseTransport } from "./noise/transport.js";
export type { XXpsk3Init } from "./noise/xxpsk3.js";
export { pureJsCrypto } from "./noise/crypto-js.js";
export { wrapCrypto } from "./noise/crypto.js";
export type { ICrypto, ICipherState, ISymmetricState, IHandshakeState, KeyPair } from "./noise/types.js";

export { LEAVE_CLOSE_CODE } from "./close-codes";
export { encodeFastRecord, decodeFastRecord, FAST_RECORD_MAX, FAST_U64_MAX } from './fast-data';
export type { FastRecord, FastStream, FastKind } from './fast-data';
export { FastDelivery } from './fast-delivery';
export type { DeliveryEffect, SendResult } from './fast-delivery';
export { FastCarrierPolicy } from './fast-carrier';
export type { FastCarrierKind, CarrierEffect } from './fast-carrier';
