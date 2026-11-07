import type { Transport } from './connection';

// An explicitly bootstrapped page may supply its own transport. The normal product entry
// never installs one; the public demo installs its in-memory transport before loading main.
let factory: ((code: string) => Transport | undefined) | undefined;
export function installPageTransport(value: (code: string) => Transport | undefined): void { factory = value; }
export function pageTransport(code: string): Transport | undefined { return factory?.(code); }
