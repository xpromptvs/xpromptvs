/**
 * The Share view's curtain control, as DATA rather than DOM.
 *
 * A SEPARATE MODULE for the reason publish-status.ts is one: the renderer has no bundler and no test
 * target, and this is a control whose label INVERTS — exactly the shape that sticks silently. It also
 * carries a real consequence, since pressing it blacks the machine's screen and cuts its local
 * keyboard and trackpad.
 *
 * WHY THE SHARE VIEW HAS THIS AT ALL: a Mac whose display sleeps drops out of
 * CGGetActiveDisplayList, which kills capture on every source, and five minutes later the session
 * locks — a state no remote client can undo, because loginwindow discards synthetic events from an
 * Aqua-session app. The curtain is the one mechanism that keeps a Mac dark to a passer-by while
 * staying awake and unlocked for rdev, and until now it was reachable only from the tray and a key
 * chord.
 */
export interface CurtainButton {
  label: string;
  disabled: boolean;
  pressed: boolean;
}

export function curtainButton(s: { sharing: boolean; curtain: boolean }): CurtainButton {
  return {
    label: s.curtain ? "Unlock screen" : "Lock screen & keep awake",
    // rdev_host_curtain_set is a no-op with no runtime, so this must be DEAD when not sharing —
    // a live-looking button that silently does nothing is worse than a visibly disabled one.
    disabled: !s.sharing,
    pressed: s.curtain,
  };
}
