/** Startup presentation shared by the native dashboard and its workbench adapter. */
export function mountLaunchDashboard(host: HTMLElement, actions: {
  local(): Promise<void>; share(): Promise<void>; connect(): void;
  readStartup(): Promise<boolean>; saveStartup(on: boolean): Promise<unknown>;
}) {
  const d = host.ownerDocument;
  const panel = d.createElement('section');
  panel.className = 'launch-dashboard';
  panel.innerHTML = `<div class="launch-heading"><p class="launch-eyebrow">YOUR WORKSPACE</p><h1 aria-label="What would you like to do?"><span class="launch-title-line" aria-hidden="true" data-shadow="What would you">What would you</span><span class="launch-title-line" aria-hidden="true" data-shadow="like to do?">like to do?</span></h1><p>Your terminal is ready behind this window.</p></div>
    <div class="launch-actions">
      <button type="button" data-launch="local"><span class="launch-symbol" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="3" y="4" width="18" height="16" rx="3"/><path d="m7 9 3 3-3 3m6 0h4"/></svg></span><span><strong>Use this Mac</strong><small>Start working in your terminal.</small></span><span aria-hidden="true">→</span></button>
      <button type="button" data-launch="share"><span class="launch-symbol" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="2" y="4" width="14" height="11" rx="2"/><path d="M5 19h8m-4-4v4"/><rect x="16" y="10" width="6" height="11" rx="1.5"/></svg></span><span><strong>Access this Mac remotely</strong><small>Use these terminals and windows from another device.</small></span><span aria-hidden="true">→</span></button>
      <button type="button" data-launch="connect"><span class="launch-symbol" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M4 8h15l-4-4m5 12H5l4 4"/><path d="m19 8-4 4M5 16l4-4"/></svg></span><span><strong>Connect to another Mac</strong><small>Choose your Mac or enter a pairing code.</small></span><span aria-hidden="true">→</span></button>
    </div><footer><label><input type="checkbox"> Show on startup</label><span>Always available in Other Devices</span></footer><p class="launch-error" role="alert" hidden></p>`;
  host.append(panel); host.classList.add('has-launch-dashboard');
  const checkbox = panel.querySelector('input')!;
  const error = panel.querySelector<HTMLElement>('.launch-error')!;
  const report = (e: unknown) => { error.hidden = false; error.textContent = e instanceof Error ? e.message : 'Please try again.'; };
  const back = d.createElement('button');
  back.type = 'button'; back.className = 'launch-back'; back.hidden = true;
  back.setAttribute('aria-label', 'Back to welcome');
  back.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true"><path d="m14 6-6 6 6 6"/></svg><span>Back</span>';
  host.querySelector('.ss-header-actions')?.prepend(back);
  let welcome = true;
  const showWelcome = (show: boolean) => { host.classList.toggle('has-launch-dashboard', show); panel.hidden = !show; back.hidden = show; };
  back.onclick = () => { welcome = true; showWelcome(true); panel.querySelector<HTMLButtonElement>('[data-launch="connect"]')!.focus(); };
  const leave = () => { welcome = false; showWelcome(false); };
  panel.querySelector<HTMLButtonElement>('[data-launch="local"]')!.onclick = () => { void actions.local().catch(report); };
  panel.querySelector<HTMLButtonElement>('[data-launch="share"]')!.onclick = () => { void actions.share().catch(report); };
  panel.querySelector<HTMLButtonElement>('[data-launch="connect"]')!.onclick = () => { leave(); actions.connect(); };
  let edited = false;
  void actions.readStartup().then(on => { if (!edited) checkbox.checked = on; }).catch(report);
  checkbox.onchange = () => {
    edited = true; checkbox.disabled = true;
    void actions.saveStartup(checkbox.checked).catch(e => { checkbox.checked = !checkbox.checked; report(e); }).finally(() => { checkbox.disabled = false; });
  };
  // Settings temporarily hides the welcome page; only an explicit connection action leaves it.
  const nav = (e: Event) => {
    const target = e.target as Element;
    if (target.closest('[data-settings]')) { showWelcome(false); back.hidden = true; }
    else if (target.closest('[data-home]')) showWelcome(welcome);
  };
  const escape = (e: KeyboardEvent) => {
    if (e.key === 'Escape' && !panel.hidden && !d.querySelector('dialog[open]')) { e.preventDefault(); void actions.local().catch(report); }
  };
  host.addEventListener('click', nav); d.addEventListener('keydown', escape);
  return () => { host.removeEventListener('click', nav); d.removeEventListener('keydown', escape); panel.remove(); back.remove(); host.classList.remove('has-launch-dashboard'); };
}
