import { it, expect, vi } from 'vitest';
import { mountLaunchDashboard } from '../src/shared/launch-dashboard';
it('routes explicit actions, persists opt-out, and leaves the existing dashboard available', async () => {
 const host = document.createElement('main'); document.body.append(host);
 const local = vi.fn(async () => {}), share = vi.fn(async () => {}), connect = vi.fn();
 const saveStartup = vi.fn(async (_on: boolean) => {});
 const dispose = mountLaunchDashboard(host, {local, share, connect, readStartup: async () => true, saveStartup});
 await Promise.resolve();
 const box = host.querySelector('input')!; expect(box.checked).toBe(true);
 box.click(); expect(saveStartup).toHaveBeenCalledWith(false);
 host.querySelector<HTMLButtonElement>('[data-launch="share"]')!.click(); expect(share).toHaveBeenCalledOnce();
 document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' })); expect(local).toHaveBeenCalledOnce();
 host.querySelector<HTMLButtonElement>('[data-launch="connect"]')!.click(); expect(connect).toHaveBeenCalledOnce();
 expect(host.classList.contains('has-launch-dashboard')).toBe(false);
 dispose(); host.remove();
});

it('keeps the welcome state across Settings and Devices without undoing explicit connection navigation', async () => {
 const host = document.createElement('main');
 host.innerHTML = '<button data-home>Devices</button><button data-settings>Settings</button>';
 document.body.append(host);
 const dispose = mountLaunchDashboard(host, {local: async()=>{}, share: async()=>{}, connect: ()=>{}, readStartup: async()=>false, saveStartup: async()=>{}});
 await Promise.resolve();
 const panel = host.querySelector<HTMLElement>('.launch-dashboard')!;
 const home = host.querySelector<HTMLButtonElement>('[data-home]')!;
 const settings = host.querySelector<HTMLButtonElement>('[data-settings]')!;
 settings.click(); expect(panel.hidden).toBe(true);
 home.click(); expect(panel.hidden).toBe(false);
 expect(host.classList.contains('has-launch-dashboard')).toBe(true);
 expect(panel.querySelector('input')!.checked).toBe(false);
 panel.querySelector<HTMLButtonElement>('[data-launch="connect"]')!.click();
 settings.click(); home.click(); expect(panel.hidden).toBe(true);
 dispose(); host.remove();
});
