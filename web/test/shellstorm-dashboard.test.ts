import { beforeEach, expect, test, vi } from 'vitest';
import { mountWelcome } from '../src/client/welcome';
import { mountDashboard } from '../src/shared/dashboard';
import { deviceListView, type DeviceListState } from '../src/shared/device-list';
import type { DirectorySession } from '@rdev/protocol';

beforeEach(() => { document.body.innerHTML=''; history.replaceState(null,'','/'); });

// **JUST THE HOST.** `shared/dashboard.ts` builds the page — the same one the native app mounts.
const HOME = `<div id="welcome" class="hidden"></div>`;

const row = (label: string, code: string): DeviceListState<DirectorySession> =>
  ({ kind: 'ready', devices: [{ label, code, token: `token-${code}`, device_id: 'd' }] });

// **The property the account panel's own test used to hold, kept across the rewrite.** `mountWelcome`
// runs again every time a session ends; a listing still in flight from the previous overlay would
// otherwise land on top of the new one, putting Macs on screen a newer listing had already replaced
// — and clicking one of those rows connects to a room that has been withdrawn.
test('a listing that outlived its mount paints nothing', async () => {
  document.body.innerHTML = HOME;
  const pending: Array<(s: DeviceListState<DirectorySession>) => void> = [];
  mountWelcome({ navigate: () => {},
                 listDevices: () => new Promise<DeviceListState<DirectorySession>>((r) => pending.push(r)) });
  await vi.waitFor(() => expect(pending.length).toBe(1));

  // The session ended and the overlay was mounted again, which aborts the first mount's signal.
  mountWelcome({ navigate: () => {}, listDevices: async () => row('New Mac', 'new') });
  await vi.waitFor(() => expect(document.querySelector('[data-session-code=new]')).not.toBeNull());

  pending[0]!(row('Stale Mac', 'old'));
  await new Promise((r) => setTimeout(r, 0));
  expect(document.querySelector('[data-session-code=new]')).not.toBeNull();
  expect(document.querySelector('[data-session-code=old]')).toBeNull();
});

// **THE ROOM TOKEN NEVER REACHES THE DOM.** It is what a stranger needs to enter the signalling
// room, and a page that puts it in an attribute has published it to anything that can read the page.
test('a row carries its code and never its token', async () => {
  document.body.innerHTML = HOME;
  const navigate = vi.fn();
  mountWelcome({ navigate, listDevices: async () => row('Studio Mac', 'AbCd1234') });
  await vi.waitFor(() =>
    expect(document.querySelector('[data-session-code=AbCd1234]')).not.toBeNull());

  expect(document.body.innerHTML).not.toContain('token-AbCd1234');
  document.querySelector<HTMLButtonElement>('[data-session-code=AbCd1234] button')!.click();
  expect(navigate).toHaveBeenCalledWith('?code=AbCd1234&token=token-AbCd1234');
});

test('native-app pairing fragment uses the real parser, clears the fragment, and navigates to the session',async()=>{
 document.body.innerHTML=HOME;
 history.replaceState(null,'','/#pairing=AAAAAAAAAAAAAAAAAAAAAA');
 const navigate=vi.fn();mountWelcome({navigate});
 await vi.waitFor(()=>expect(navigate).toHaveBeenCalled());
 expect(navigate).toHaveBeenCalledWith('?code=1DB6haeo&token=0d002ad3-28b2-4e70-b483-8fae577d1756#pair=AAAAAAAAAAAAAAAAAAAAAA');
 expect(location.hash).toBe('');
});
test('invalid native-app handoff shows a visible error',async()=>{
 document.body.innerHTML=HOME;
 history.replaceState(null,'','/#pairing=bad');const navigate=vi.fn();mountWelcome({navigate});
 await vi.waitFor(()=>expect(document.getElementById('home-error')!.hidden).toBe(false));
 expect(navigate).not.toHaveBeenCalled();
 expect(document.getElementById('home-input')).toBeNull();
 expect(document.getElementById('home-error')!.hidden).toBe(false);
});

// **SIGNING IN FROM THE DASHBOARD.** A browser holding no identity used to be told only to pair with
// a Mac, which strands anyone whose passkey is on another device — the half of the OAuth removal
// that was missing. The panel it opens is the same one a client mounts mid-connection.
test('the empty state offers a passkey, and the button opens the identity panel', async () => {
  document.body.innerHTML = HOME
    + '<dialog id="e2e-setup"><h2 id="e2e-setup-title"></h2><p id="e2e-setup-body"></p>'
    + '<code id="e2e-setup-identity" hidden></code><div id="e2e-setup-actions"></div></dialog>';
  mountWelcome({ navigate: () => {}, listDevices: async () => ({ kind: 'no-identity' }) });

  const button = await vi.waitFor(() => {
    const el = document.querySelector<HTMLButtonElement>('[data-device-action=sign-in]');
    expect(el).not.toBeNull();
    return el!;
  });
  expect(button.textContent).toMatch(/passkey/i);
  // jsdom 25 implements neither `showModal` nor `close`, so the attribute is all a unit test can
  // see; `e2e/shellstorm-ui-check.mjs` asserts what is actually painted.
  expect(document.getElementById('e2e-setup')!.hasAttribute('open')).toBe(false);

  button.click();
  // The panel takes over from here; what matters is that the click reaches it at all.
  expect(document.getElementById('e2e-setup')!.hasAttribute('open')).toBe(true);
  const labels = [...document.querySelectorAll('#e2e-setup-actions button')].map((b) => b.textContent);
  expect(labels).toEqual(['Use a passkey', 'Create a passkey', 'Not now']);
});

// **A FAILED LISTING KEEPS THE ROWS, AND THEIR TOKENS.** On a weak network one listing in several
// fails; the list used to turn into an error each time, and the token map was emptied with it, so a
// row that did come back could not connect until the next good answer.
test('a failed refresh keeps the last rows, marked stale, and they still connect', async () => {
  document.body.innerHTML = HOME;
  const navigate = vi.fn();
  const answers: Array<DeviceListState<DirectorySession>> = [row('Studio Mac', 'AbCd1234'), { kind: 'unreachable' }];
  mountWelcome({ navigate, listDevices: async () => answers.shift() ?? { kind: 'unreachable' } });
  await vi.waitFor(() =>
    expect(document.querySelector('[data-session-code=AbCd1234]')).not.toBeNull());

  document.querySelector<HTMLButtonElement>('#home-refresh button')!.click();
  await vi.waitFor(() =>
    expect(document.querySelector('.ss-device-message')?.textContent).toMatch(/last time/i));
  expect(document.querySelector('[data-session-code=AbCd1234]')).not.toBeNull();

  document.querySelector<HTMLButtonElement>('[data-session-code=AbCd1234] button')!.click();
  expect(navigate).toHaveBeenCalledWith('?code=AbCd1234&token=token-AbCd1234');
});

// "Looking for your Macs…" over rows would make a list that polls itself unclickable every 15 s.
test('refreshing over rows never paints the loading state', async () => {
  document.body.innerHTML = HOME;
  let release: (s: DeviceListState<DirectorySession>) => void = () => {};
  let calls = 0;
  mountWelcome({ navigate: () => {}, listDevices: () => {
    calls++;
    return calls === 1 ? Promise.resolve(row('Studio Mac', 'AbCd1234'))
                       : new Promise((r) => { release = r; });
  } });
  await vi.waitFor(() =>
    expect(document.querySelector('[data-session-code=AbCd1234]')).not.toBeNull());

  const button = document.querySelector<HTMLButtonElement>('#home-refresh button')!;
  button.click();
  await vi.waitFor(() => expect(calls).toBe(2));
  expect(document.querySelector('[data-session-code=AbCd1234]')).not.toBeNull();
  expect(document.getElementById('home-device-list')!.textContent).not.toMatch(/Looking/);
  // The button says it is working instead.
  expect(button.textContent).toBe('refreshing…');
  expect(button.disabled).toBe(true);
  release(row('Studio Mac', 'AbCd1234'));
});

// **THE STREAM PAINTS THROUGH THE SAME PATH A POLL DOES**, tokens included.
test('a streamed snapshot paints rows that connect', async () => {
  document.body.innerHTML = HOME;
  const navigate = vi.fn();
  let push: (e: import('../src/shared/dashboard').DeviceWatchEvent) => void = () => {};
  mountWelcome({ navigate, listDevices: async () => ({ kind: 'ready', devices: [] }),
                 watchDevices: (onEvent) => { push = onEvent; return { ping: () => {} }; } });
  await vi.waitFor(() => expect(document.getElementById('home-device-list')!.textContent).toBe(deviceListView({ kind: 'ready', devices: [] }, 'browser').message));
  push({ kind: 'state', state: row('Studio Mac', 'AbCd1234') });
  await vi.waitFor(() =>
    expect(document.querySelector('[data-session-code=AbCd1234]')).not.toBeNull());
  document.querySelector<HTMLButtonElement>('[data-session-code=AbCd1234] button')!.click();
  expect(navigate).toHaveBeenCalledWith('?code=AbCd1234&token=token-AbCd1234');
});

// A poll that was already in flight when a snapshot arrived must not paint OVER it.
test('an older poll never overwrites a newer streamed snapshot', async () => {
  document.body.innerHTML = HOME;
  let release: (s: DeviceListState<DirectorySession>) => void = () => {};
  let calls = 0;
  let push: (e: import('../src/shared/dashboard').DeviceWatchEvent) => void = () => {};
  mountWelcome({ navigate: () => {},
    listDevices: () => { calls++; return calls === 1 ? Promise.resolve(row('Old', 'old'))
                                                     : new Promise((r) => { release = r; }); },
    watchDevices: (onEvent) => { push = onEvent; return { ping: () => {} }; } });
  await vi.waitFor(() => expect(document.querySelector('[data-session-code=old]')).not.toBeNull());
  document.querySelector<HTMLButtonElement>('#home-refresh button')!.click();
  await vi.waitFor(() => expect(calls).toBe(2));
  push({ kind: 'state', state: row('New', 'new') });
  await vi.waitFor(() => expect(document.querySelector('[data-session-code=new]')).not.toBeNull());
  release(row('Old', 'old'));
  await new Promise((r) => setTimeout(r, 0));
  expect(document.querySelector('[data-session-code=new]')).not.toBeNull();
  expect(document.querySelector('[data-session-code=old]')).toBeNull();
});

// Signing out must stop the old identity's stream: its late snapshot must paint nothing.
test('restarting the watch drops the previous stream', async () => {
  document.body.innerHTML = HOME;
  const pushes: Array<(e: import('../src/shared/dashboard').DeviceWatchEvent) => void> = [];
  const signals: AbortSignal[] = [];
  mountWelcome({ navigate: () => {}, listDevices: async () => ({ kind: 'no-identity' }),
                 watchDevices: (onEvent, signal) => { pushes.push(onEvent); signals.push(signal);
                                                      return { ping: () => {} }; } });
  await vi.waitFor(() => expect(pushes.length).toBeGreaterThan(0));
  const first = pushes.length - 1;
  expect(signals[first]!.aborted).toBe(false);
  // A second mount is what every sign-in/sign-out path amounts to for the stream: the old one
  // must be ABORTED, and a late snapshot from it must paint nothing.
  mountWelcome({ navigate: () => {}, listDevices: async () => ({ kind: 'no-identity' }),
                 watchDevices: () => ({ ping: () => {} }) });
  expect(signals[first]!.aborted).toBe(true);
  pushes[first]!({ kind: 'state', state: row('Ghost', 'ghost') });
  await new Promise((r) => setTimeout(r, 0));
  expect(document.querySelector('[data-session-code=ghost]')).toBeNull();
});

test('a stream that gave up is tried again when the network returns; a refused one is not', async () => {
  document.body.innerHTML = HOME;
  const pushes: Array<(e: import('../src/shared/dashboard').DeviceWatchEvent) => void> = [];
  mountWelcome({ navigate: () => {}, listDevices: async () => ({ kind: 'ready', devices: [] }),
                 watchDevices: (onEvent) => { pushes.push(onEvent); return { ping: () => {} }; } });
  await vi.waitFor(() => expect(pushes.length).toBe(1));
  pushes[0]!({ kind: 'stopped', retry: false });
  window.dispatchEvent(new Event('online'));
  expect(pushes.length).toBe(1);
  pushes[0]!({ kind: 'stopped', retry: true });
  window.dispatchEvent(new Event('online'));
  expect(pushes.length).toBe(2);
});

// **A PUSHED LISTING (the app's `subscribe`) PAINTS THROUGH THE SAME PATH A POLL DOES** — settled,
// deduplicated, and newer than any forced poll still in flight when it arrived.
const mountMac = (listDevices: (force: boolean) => Promise<DeviceListState>) => {
  document.body.innerHTML = `<div id="home"></div>`;
  return mountDashboard({ host: document.getElementById('home')!, adapter: {
    surface: 'mac', listDevices, connect: () => {}, quickConnect: () => {},
    identity: async () => ({ kind: 'signed-out' }), logOut: () => {} } });
};

test('applyDevices paints a pushed listing, and an unchanged one repaints nothing', async () => {
  const d = mountMac(async () => ({ kind: 'no-identity' }));
  void d.refreshDevices();
  await vi.waitFor(() => expect(document.getElementById('home-device-list')!.textContent).not.toBe(''));
  d.applyDevices({ kind: 'ready', devices: [{ label: 'Studio Mac', code: 'AbCd1234' }] });
  const painted = document.querySelector('[data-session-code=AbCd1234]');
  expect(painted).not.toBeNull();
  d.applyDevices({ kind: 'ready', devices: [{ label: 'Studio Mac', code: 'AbCd1234' }] });
  // The SAME element: a push that changed nothing must not rebuild the row under a cursor.
  expect(document.querySelector('[data-session-code=AbCd1234]')).toBe(painted);
});

test('a forced poll in flight when a listing is pushed paints nothing', async () => {
  let calls = 0;
  let release: (s: DeviceListState) => void = () => {};
  const d = mountMac(() => { calls++; return calls === 1
    ? Promise.resolve({ kind: 'ready', devices: [{ label: 'Old', code: 'old' }] })
    : new Promise((r) => { release = r; }); });
  void d.refreshDevices();
  await vi.waitFor(() => expect(document.querySelector('[data-session-code=old]')).not.toBeNull());
  void d.refreshDevices(true);
  await vi.waitFor(() => expect(calls).toBe(2));
  d.applyDevices({ kind: 'ready', devices: [{ label: 'New', code: 'new' }] });
  expect(document.querySelector('[data-session-code=new]')).not.toBeNull();
  release({ kind: 'ready', devices: [{ label: 'Old', code: 'old' }] });
  await new Promise((r) => setTimeout(r, 0));
  expect(document.querySelector('[data-session-code=new]')).not.toBeNull();
  expect(document.querySelector('[data-session-code=old]')).toBeNull();
});

// **SMOOTH SCROLLING IS A SETTING OF THIS DEVICE**, on the Settings page of both dashboards (the
// markup is shared) and in the session's Terminal Settings; one saved value (`shared/smooth-scroll-pref.ts`).
function memStore(): Storage {
  const m = new Map<string, string>();
  return { getItem: (k) => m.get(k) ?? null, setItem: (k, v) => void m.set(k, v), removeItem: (k) => void m.delete(k),
           clear: () => m.clear(), key: () => null, get length() { return m.size; } } as Storage;
}
const smoothBox = () => document.querySelector<HTMLInputElement>('#home-settings input[data-smooth-scroll]');

test('Settings offers smooth scrolling, ON by default, reachable by the glasses D-pad', async () => {
  vi.stubGlobal('localStorage', memStore());
  try {
    document.body.innerHTML = HOME;
    mountWelcome({ navigate: () => {} });
    const box = smoothBox();
    expect(box).not.toBeNull();
    expect(box!.type).toBe('checkbox');
    expect(box!.checked).toBe(true);   // on unless saved off (smooth-scroll-pref.ts)
    expect(box!.dataset.navId).toBe('home:smooth-scroll');
    expect(box!.closest('label')!.textContent).toContain('Smooth scrolling');
  } finally { vi.unstubAllGlobals(); }
});

test('the checkbox saves the preference, shows what is saved, and follows a change made elsewhere', async () => {
  vi.stubGlobal('localStorage', memStore());
  try {
    const { smoothScrollEnabled, setSmoothScroll } = await import('../src/shared/smooth-scroll-pref');
    document.body.innerHTML = HOME;
    mountWelcome({ navigate: () => {} });
    const box = smoothBox()!;
    box.checked = true;
    box.dispatchEvent(new Event('change', { bubbles: true }));
    expect(smoothScrollEnabled()).toBe(true);

    document.body.innerHTML = HOME;                   // the overlay is mounted again after a session
    mountWelcome({ navigate: () => {} });
    expect(smoothBox()!.checked).toBe(true);
    setSmoothScroll(false);                           // the palette, in the same document
    expect(smoothBox()!.checked).toBe(false);
  } finally { vi.unstubAllGlobals(); }
});

// **"THIS MAC" IS THE APP'S: ABOVE THE LIST, IN EVERY LIST STATE, NEVER REPAINTED, NEVER COUNTED.**
test("the app's This Mac row sits above the list in every state and is not a listed Mac", async () => {
  document.body.innerHTML = `<div id="home"></div>`;
  const connect = vi.fn();
  const d = mountDashboard({ host: document.getElementById('home')!, adapter: {
    surface: 'mac', listDevices: async () => ({ kind: 'no-identity' }), connect: () => {}, quickConnect: () => {},
    identity: async () => ({ kind: 'signed-out' }), logOut: () => {}, thisMac: { connect } } });
  const holder = document.getElementById('home-this-mac')!;
  const row = holder.querySelector<HTMLElement>('.ss-device')!;
  expect(holder.hidden).toBe(false);
  expect(document.getElementById('home-local')!.hidden).toBe(false);
  expect(row.querySelector('button')!.textContent).toBe('Open terminal');
  expect(document.activeElement?.id).not.toBe('home-input');
  expect(row.querySelector('.ss-device-name')!.textContent).toBe('Terminal');
  expect(row.hasAttribute('data-session-code')).toBe(false);
  expect(holder.compareDocumentPosition(document.getElementById('home-device-list')!) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  const ready: DeviceListState = { kind: 'ready', devices: [{ label: 'Studio Mac', code: 'AbCd1234' }] };
  for (const state of [{ kind: 'loading' }, { kind: 'unreachable' }, ready] as DeviceListState[]) {
    d.applyDevices(state);
    expect(holder.querySelector('.ss-device')).toBe(row);
  }
  expect(document.querySelectorAll('[data-session-code]')).toHaveLength(1);
  expect(document.getElementById('home-device-count')).toBeNull();
  row.querySelector<HTMLButtonElement>('button')!.click();
  expect(connect).toHaveBeenCalledWith(row);
});

test('a surface without thisMac shows no This Mac row', () => {
  mountMac(async () => ({ kind: 'no-identity' }));
  const holder = document.getElementById('home-this-mac')!;
  expect(holder.hidden).toBe(true);
  expect(holder.childElementCount).toBe(0);
});

test('one remote sign-in serves both capabilities and device rows return after sign-in', () => {
  document.body.innerHTML = '<div id="home"></div>';
  const signIn = vi.fn(), connect = vi.fn();
  const d = mountDashboard({host: document.getElementById('home')!, adapter: {
    surface:'mac', listDevices:async()=>({kind:'no-identity'}), connect, quickConnect:()=>{},
    identity:async()=>({kind:'signed-out'}), logOut:()=>{}, signIn, thisMac:{connect:()=>{}} }});
  const list = document.getElementById('home-device-list')!;
  d.applyDevices({kind:'no-identity'});
  expect(list.parentElement!.id).toBe('home-remote-signin-slot');
  expect(document.getElementById('home-macs-section')!.hidden).toBe(true);
  list.querySelector<HTMLButtonElement>('button')!.click();
  expect(signIn).toHaveBeenCalledOnce();
  d.applyDevices({kind:'ready',devices:[{label:'Studio',code:'studio'}]});
  expect(list.parentElement!.id).toBe('home-macs-list-slot');
  expect(document.getElementById('home-remote-signin')!.hidden).toBe(true);
  list.querySelector<HTMLButtonElement>('button')!.click();
  expect(connect).toHaveBeenCalledWith('studio',list.querySelector('.ss-device'));
  d.applyDevices({kind:'no-identity'});
  expect(list.parentElement!.id).toBe('home-remote-signin-slot');
  expect(list.querySelector('[data-session-code]')).toBeNull();
  d.applyDevices({kind:'ready',devices:[]});
  expect(document.getElementById('home-macs-section')!.hidden).toBe(true);
  expect(list.textContent).toMatch(/Sharing/);
});
