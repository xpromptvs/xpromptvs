import { createSourceWindowController } from './document';
import type { NativeSourceDocumentBridge, SourceWindowController } from './types';

declare global {
  interface Window {
    __rdevNativeSource?: NativeSourceDocumentBridge;
    __rdevSourceController?: SourceWindowController;
  }
}
const root = document.getElementById('source-root')!;
const bridge = window.__rdevNativeSource;
if (bridge) {
  root.textContent = '';
  const controller = createSourceWindowController(root, bridge);
  Object.defineProperty(window, '__rdevSourceController', { value: controller });
  window.addEventListener('pagehide', () => controller.dispose(), { once: true });
  void bridge.ready?.().catch(error => { controller.dispose(); console.error('[native-source] ready', error); });
} else {
  root.textContent = 'This source window is unavailable.';
}
