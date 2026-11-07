// Mount the shipped session fixture in its actual embedded presentation boundary.
export async function mountSessionShell(page) {
  await page.evaluate(async () => {
    const root=window.__rdevClientRoot,ui=root?.querySelector('.client-root');
    if(!ui)throw Error('Canonical client surface unavailable');
    const body=ui.querySelector('.client-body');
    body.innerHTML=await (await fetch('/src/client/instance/session.html')).text();
    ui.dataset.tab='sim';
    document.getElementById('welcome')?.remove();
    const wrapper=root.host.parentElement;
    wrapper.style.cssText='position:fixed;inset:0;display:block;transform:none;opacity:1';
  });
}
