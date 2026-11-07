// The product decoder in test probes: measurements must consume the complete shared wire.
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
const require = createRequire(new URL('../../web/package.json', import.meta.url));
const { buildSync } = require('esbuild');
const entry = fileURLToPath(new URL('../../web/src/client/term-wire.ts', import.meta.url));
const bundle = (format) => buildSync({ entryPoints: [entry], bundle: true, write: false,
  format, ...(format === 'iife' ? { globalName: 'RdevTermProbe' } : {}) }).outputFiles[0].text;
const { TermWireDecoder } = await import(`data:text/javascript;base64,${Buffer.from(bundle('esm')).toString('base64')}`);
export const installTermProbe = (context) => context.addInitScript({ content: bundle('iife') + '\nwindow.RdevTermProbe = RdevTermProbe;'  });
export function decodeCapture(messages) {
  let current = null;
  const decoder = new TermWireDecoder({ start: () => { current = { start: true }; },
    record: frame => { current = frame; }, failed: error => { throw error; } });
  return messages.map(message => {
    current = null;
    decoder.receive(Buffer.from(message, 'base64'));
    return current;
  });
}
