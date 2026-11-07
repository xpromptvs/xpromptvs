import { afterEach, describe, expect, it } from 'vitest';
import { createPasteDialogs } from '../src/client/paste-dialogs';
import { createClientSurface } from '../src/client/instance/surface';
import { createClientContext } from '../src/client/instance/context';
import { createMemoryPreferences } from '../src/client/instance/preferences';
const cleanups: (() => void)[] = [];
afterEach(() => { for (const cleanup of cleanups.splice(0).reverse()) cleanup(); });
function mount(id: string) {
  const surface = createClientSurface(document.body);
  const context = createClientContext(id, surface.root, surface.ui, createMemoryPreferences(), { layout: 'floating' });
  cleanups.push(() => { context.scope.dispose(); surface.destroy(); });
  return { context, dialogs: createPasteDialogs(context) };
}
describe('paste dialogs owned by their presenting surface', () => {
  it('answers only the clicked surface and keeps the other question open', async () => {
    const a = mount('a'), b = mount('b');
    const first = a.dialogs.confirm('Paste 3 lines? Each runs.');
    const second = b.dialogs.confirm('Send file?', 'Send');
    a.context.get('paste-lines-confirm').click();
    expect(await first).toBe(true);
    expect(b.context.get<HTMLDialogElement>('paste-lines-dialog').open).toBe(true);
    expect(b.context.get('paste-lines-confirm').textContent).toBe('Send');
    b.context.get('paste-lines-cancel').click();
    expect(await second).toBe(false);
  });
  it('replaces a pending confirmation with a folder question, and cancels on disposal', async () => {
    const a = mount('a');
    const first = a.dialogs.confirm('Paste?');
    const second = a.dialogs.chooseFolder({ title: 'Folder', body: 'Choose', path: 'Path', send: 'Zip' });
    expect(await first).toBe(false);
    expect(a.context.get<HTMLDialogElement>('paste-lines-dialog').open).toBe(false);
    a.context.scope.dispose();
    expect(await second).toBe(null);
  });
  it('a delayed close notification cannot cancel the replacement question', async () => {
    const a = mount('a');
    const first = a.dialogs.confirm('First?');
    const second = a.dialogs.confirm('Second?');
    expect(await first).toBe(false);
    a.context.get('paste-lines-dialog').dispatchEvent(new Event('close'));
    a.context.get('paste-lines-confirm').click();
    expect(await second).toBe(true);
  });
});
