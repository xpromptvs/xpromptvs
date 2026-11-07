import type { SessionScope } from "../session-scope";

export function createClientInput(root: ShadowRoot, scope: SessionScope) {
  let keyboardOwner: (() => void) | null = null;
  const releases = new Set<() => void>();
  const release = () => {
    const owner = keyboardOwner; keyboardOwner = null; owner?.();
    for (const fn of [...releases]) fn();
  };
  const focused = () => root.activeElement !== null;
  const document = root.ownerDocument, win = document.defaultView!;
  scope.listen(win,"blur",release);
  scope.listen(win,"pagehide",release);
  scope.listen(document,"visibilitychange",()=>{if(document.hidden)release();});
  // Consume handled keys before they reach the embedding page. Other root listeners (the
  // client's palette shortcut included) still receive them at this same boundary.
  for (const type of ["keydown", "keyup", "beforeinput"])
    scope.listen(root,type,event=>{if(event.defaultPrevented)event.stopPropagation();});
  scope.listen(root,"focusout",()=>{queueMicrotask(scope.guard(()=>{if(!focused())release();}));});
  scope.defer(release,"input-release");
  return {
    owns: (event: Event) => event.composedPath().includes(root), focused, release,
    claimKeyboard(owner: () => void) { if (keyboardOwner !== owner) { const old = keyboardOwner; keyboardOwner=owner; old?.(); } },
    releaseKeyboard(owner: () => void) { if(keyboardOwner === owner) { keyboardOwner=null; owner(); } },
    onRelease(fn: () => void) { releases.add(fn); return () => {releases.delete(fn);}; },
  };
}
