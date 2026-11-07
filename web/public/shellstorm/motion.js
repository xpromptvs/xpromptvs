/* Product-state adapter for the original ShellStorm motion modules. No simulated connection clock. */
(() => {
  const root = document.documentElement;
  const nativeClient = !!window.__rdevShell;
  if (nativeClient) root.dataset.nativeClient = "true";
  const media = matchMedia('(prefers-reduced-motion: reduce)');
  const handoff = new URLSearchParams(location.search);
  const handedSlow = handoff.get('motionSlow') === '1';
  // Consume presentation-only handoff flags; pairing and protocol parameters remain untouched.
  if (handoff.has('motionSlow')) {
    handoff.delete('motionSlow');
    history.replaceState(null,'',location.pathname + (handoff.size ? '?' + handoff : '') + location.hash);
  }
  let active = null;
  let returning = null;
  const reduced = () => media.matches;
  const quick = () => document.querySelector('[data-connect-quick]');
  const session = document.getElementById('session');
  const sessionRoot = () => session?.querySelector('[data-client-host]')?.shadowRoot;
  const all = selector => [...document.querySelectorAll(selector), ...sessionRoot()?.querySelectorAll(selector) ?? []];
  const welcome = document.getElementById('welcome');
  const onIdle = new Set();
  function finish() {
    ConnectionMotion.finishAll(); ComputerMotion.finishAll(); SessionMotion.finish();
    if (active && !active.visualReady) {
      MotionDebug.cancel(active.readyTimer); active.visualReady = true;
      const callbacks = active.readyCallbacks.splice(0);
      for (const callback of callbacks) callback();
    }
  }
  function syncMotion() {
    if (reduced()) finish();
  }
  function syncDebug() {
    const debug = location.hash === '#debug' || new URLSearchParams(location.search).has('debug');
    all('[data-motion-slow]').forEach(b => b.hidden = !debug);
    if (!debug) MotionDebug.setSlow(false);
  }
  const screenHalo = GlowRaster.sprite(15.2, 10.2, 4.5455);
  root.style.setProperty('--ss-cursor-glow-white', `url("${GlowRaster.sprite(10.4,17.6,3).url}")`);
  root.style.setProperty('--ss-cursor-glow-dark', `url("${GlowRaster.sprite(10.4,17.6,3,37).url}")`);
  function decorate() {
    document.querySelectorAll('.ss-connect-label, [data-connect-quick]').forEach(button => {
      if (!button.hasAttribute('data-fixed-connect')) ConnectionMotion.sizeButton(button);
    });
    document.querySelectorAll('.ss-device').forEach((row, index) => {
      row.classList.add('device-card');
      row.dataset.deviceId ??= row.getAttribute('data-session-code') ?? `device-${index}`;
      row.querySelector('.ss-device-state')?.classList.add('device-state');
      row.querySelector('.ss-connect-label, button')?.classList.add('row-connect');
      const svg = row.querySelector('.ss-device-icon svg');
      if (svg && !svg.querySelector('.computer-screen-light')) {
        const light = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
        for (const [key,value] of Object.entries({class:'computer-screen-light',x:'4.4',y:'5.4',width:'15.2',height:'10.2',rx:'.8'})) light.setAttribute(key,value);
        const glow = document.createElementNS('http://www.w3.org/2000/svg', 'image');
        for (const [key,value] of Object.entries({class:'computer-screen-glow',href:screenHalo.url,x:4.4-screenHalo.pad,y:5.4-screenHalo.pad,width:screenHalo.width,height:screenHalo.height})) glow.setAttribute(key,String(value));
        svg.prepend(glow, light);
      }
    });
  }
  function phase(text) {
    if (!active || active.phase === text) return;
    active.phase = text;
    ConnectionMotion.status(active.status, text, reduced());
  }
  function begin({row = null, button = null, onCancel = () => {}, onRestored = () => {}} = {}) {
    if (active || returning) return false;
    decorate();
    ConnectionMotion.finishAll(); ComputerMotion.finishAll();
    const rowButton = row?.querySelector('.row-connect');
    const buttons = [...new Set([rowButton, button].filter(Boolean))];
    const widths = buttons.map(b => b.getBoundingClientRect().width);
    const oldButtons = buttons.map(b => ({b,text:b.textContent,label:b.getAttribute('aria-label')}));
    const status = row?.querySelector('.device-state') ?? document.querySelector('[data-quick-status]');
    active = {visualReady:reduced(), readyCallbacks:[], row, rowLabel:row?.getAttribute('aria-label'), buttons:oldButtons, status, text:status?.textContent ?? '', onCancel, onRestored, phase:null};
    row?.classList.add('is-connecting','is-lit');
    row?.setAttribute('aria-busy','true');
    if (row?.matches('button')) row.setAttribute('aria-label','Cancel connection');
    const locks = [...document.querySelectorAll('.device-card button, .ss-heading-label button, #welcome-add-device, #home-input')];
    active.locks = locks.filter(b => !buttons.includes(b) && b !== row && !b.disabled);
    for (const b of active.locks) { b.disabled = true; b.classList.add('pending-lock'); }
    if (status) status.hidden = false;
    buttons.forEach((b,i) => {
      b.disabled = false;
      b.classList.add('is-busy'); b.setAttribute('aria-label','Cancel connection');
      ConnectionMotion.setConnecting(b);
      ConnectionMotion.run(b,widths[i],reduced());
    });
    if (!active.visualReady) {
      const attempt = active;
      attempt.readyTimer = MotionDebug.after(() => {
        attempt.visualReady = true;
        const callbacks = attempt.readyCallbacks.splice(0);
        for (const callback of callbacks) callback();
      },520 / 1.5);
    }
    phase('Waiting for connection…');
    if (row) ComputerMotion.start(row,reduced(),true);
    return true;
  }
  function whenReady(callback) {
    if (!active || active.visualReady) callback(); else active.readyCallbacks.push(callback);
  }
  function restore(connected = false) {
    if (!active) return;
    if (connected && !active.visualReady) { whenReady(() => restore(true)); return; }
    const a = active;
    MotionDebug.cancel(a.readyTimer); a.readyCallbacks.length = 0;
    const snapshot = ConnectionMotion.captureReturn(a.row, a.buttons.find(({b}) => b === quick())?.b);
    const icon = a.row ? ComputerMotion.capture().get(a.row.dataset.deviceId) : null;
    active = null;
    ConnectionMotion.finishAll(); ComputerMotion.finishAll();
    a.row?.classList.remove('is-connecting');
    a.row?.classList.toggle('is-lit',connected);
    a.row?.removeAttribute('aria-busy');
    if (a.row && a.rowLabel != null) a.row.setAttribute('aria-label',a.rowLabel);
    for (const {b,text,label} of a.buttons) {
      b.classList.remove('is-busy'); b.textContent = text;
      if (label === null) b.removeAttribute('aria-label'); else b.setAttribute('aria-label',label);
    }
    for (const b of a.locks) { b.disabled = false; b.classList.remove('pending-lock'); }
    if (a.status) { a.status.textContent = connected ? 'Connected' : a.text; a.status.removeAttribute('aria-label'); }
    if (a.row) ComputerMotion.start(a.row,reduced(),connected,icon);
    if (!connected) ConnectionMotion.returnToIdle(snapshot,reduced());
    const done = () => {
      returning = null;
      if (!a.row && a.status) a.status.hidden = true;
      if (!connected) a.onRestored(); for (const callback of onIdle) callback();
    };
    if (reduced() || connected || document.hidden) done();
    else returning = MotionDebug.after(done,520 / 1.5 / 1.8);
  }
  function unlight(row) {
    if (active?.row === row) {restore(); return;}
    if (!row.isConnected) return;
    const previous = ComputerMotion.capture();
    ComputerMotion.finishAll();
    row.classList.remove('is-lit');
    // **BACK TO THE ROW'S OWN RESTING WORD** (`data-resting-state`, written by `device-list.ts`'s
    // `deviceRow`): "Online" for a listed Mac, "Terminal" for This Mac. A hard-coded word left This Mac
    // wearing "Online" after its window closed — as it once left every row wearing a retired word.
    const state = row.querySelector('.device-state');
    if (state) state.textContent = row.dataset.restingState ?? 'Online';
    // Preserve the original glow on other connected devices while this screen fades out.
    document.querySelectorAll('.device-card').forEach(device =>
      ComputerMotion.start(device,reduced(),device.classList.contains('is-lit'),previous.get(device.dataset.deviceId)));
  }
  function cancel() {
    if (!active) return false;
    // A connected event arriving during the retreat must not reveal a canceled attempt.
    session?.classList.remove('ss-session-pending');
    if (session) delete session.dataset.ready;
    active.onCancel(); restore(); return true;
  }
  function prepareSession() {
    if (!session || !welcome || welcome.classList.contains('hidden')) return;
    session.classList.add('ss-session-pending'); session.inert = true;
  }
  function connected() {
    if (!session?.classList.contains('ss-session-pending')) return;
    if (active && !active.visualReady) {whenReady(connected); return;}
    if (nativeClient) {
      restore(true);
      delete session.dataset.ready;
      session.classList.remove('ss-session-pending');
      session.inert = false;
      welcome.classList.add('hidden'); welcome.inert = false;
      return;
    }
    if (document.hidden) { session.dataset.ready = 'true'; return; }
    delete session.dataset.ready;
    restore(true);
    session.classList.remove('ss-session-pending'); session.classList.add('ss-session-moving');
    session.inert = false; welcome.inert = true;
    SessionMotion.open(() => {
      welcome.classList.add('hidden'); welcome.inert = false;
      session.classList.remove('ss-session-moving');
    });
  }
  function close(callback) {
    if (!session || nativeClient) { callback(); return; }
    SessionMotion.finish();
    welcome?.classList.remove('hidden');
    session.classList.add('ss-session-moving'); session.inert = true;
    SessionMotion.close(() => { session.classList.remove('ss-session-moving'); callback(); });
  }
  document.addEventListener('click', e => {
    if (!active) return;
    const action = e.target.closest('button, .row-connect');
    if (!action || (!active.buttons.some(({b}) => b === action || b.contains(action)) && action !== active.row)) return;
    e.preventDefault(); e.stopImmediatePropagation(); cancel();
  },true);
  document.addEventListener('keydown',e => {
    if (e.key === 'Escape' && active && !document.querySelector('dialog[open]') && !sessionRoot()?.querySelector('dialog[open]')) {e.preventDefault(); e.stopImmediatePropagation(); cancel();}
  },true);
  document.addEventListener('visibilitychange', () => {if (!document.hidden && session?.dataset.ready === 'true') connected();});
  media.addEventListener('change',syncMotion);
  window.addEventListener('hashchange',syncDebug);
  // Status changes come from the real peer/signaling path, never a timer.
  document.addEventListener('shellstorm:connection-state',e => {
    const {state,text} = e.detail;
    if (state === 'connected') connected();
    else phase(state === 'error' ? text : /waiting/.test(text) ? 'Waiting for connection…' : 'Setting up…');
  });
  // The dashboard is mounted dynamically; keep row decoration and debug controls in sync.
  const resync = () => { decorate(); syncDebug(); };
  new MutationObserver(resync).observe(document.querySelector('.ss-home') ?? document.body,{childList:true,subtree:true});
  decorate(); syncMotion(); syncDebug();
  document.fonts.ready.then(() => document.querySelectorAll('[data-fixed-connect]').forEach(button => ConnectionMotion.sizeButton(button)));
  window.addEventListener('resize', () => document.querySelectorAll('[data-fixed-connect]').forEach(button => ConnectionMotion.sizeButton(button)));
  if (handedSlow && handoff.has('debug')) MotionDebug.setSlow(true);
  window.ShellstormMotion = {unlight,whenReady,begin,cancel,phase,restore,prepareSession,connected,close,finish,reduced,resync,
                              retint:() => SessionMotion.retint(),
                              get active(){return !!active;},get returning(){return !!returning;}};
})();
