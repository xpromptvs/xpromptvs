// Safari can retain :hover after a tap. Only an actual mouse may highlight.
const hoverRoot = document.documentElement;
hoverRoot.classList.toggle('mouse-hover', matchMedia('(hover: hover) and (pointer: fine)').matches);
function updateHoverInput(event) {
  hoverRoot.classList.toggle('mouse-hover', event.pointerType === 'mouse');
}
document.addEventListener('pointerover', updateHoverInput, {capture:true, passive:true});
document.addEventListener('pointerdown', updateHoverInput, {capture:true, passive:true});

// One debug speed for CSS, Web Animations, and the simulated session timeline.
const MotionDebug = (() => {
  let scale = 1;
  const animations = new Set(), timers = new Set(), animeAnimations = new Set();
  function arm(timer) {
    timer.started = performance.now();
    timer.handle = setTimeout(() => {
      timers.delete(timer);
      timer.callback();
    }, timer.remaining * (timer.scaled ? scale : 1));
  }
  function after(callback, delay, scaled = true) {
    const timer = {callback, remaining: delay, scaled};
    timers.add(timer); arm(timer); return timer;
  }
  function cancel(timer) {
    if (!timer) return;
    clearTimeout(timer.handle); timers.delete(timer);
  }
  function track(animation) {
    animation.updatePlaybackRate(1 / scale);
    animations.add(animation);
    animation.finished.then(() => animations.delete(animation), () => animations.delete(animation));
    return animation;
  }
  function trackAnime(animation) {
    animation.speed = 1 / scale;
    animeAnimations.add(animation);
    return () => animeAnimations.delete(animation);
  }
  function setSlow(slow) {
    const now = performance.now();
    for (const timer of timers) {
      clearTimeout(timer.handle);
      timer.remaining = Math.max(0, timer.remaining - (now - timer.started) / (timer.scaled ? scale : 1));
    }
    scale = slow ? 10 : 1;
    document.documentElement.style.setProperty('--motion-scale', scale);
    for (const animation of animations) animation.updatePlaybackRate(1 / scale);
    for (const animation of animeAnimations) animation.speed = 1 / scale;
    for (const timer of timers) arm(timer);
    // **QUERIED EACH TIME, not a snapshot.** The dashboard's header is BUILT
    // (`web/src/shared/dashboard.ts`), so its toggle does not exist when this module loads; a list
    // collected once would leave that one unlabelled and — before the delegated listener below —
    // completely inert, which reads exactly like "Slow 10x does nothing".
    for (const toggle of [...document.querySelectorAll('[data-motion-slow]'), ...(window.__rdevClientRoot?.querySelectorAll('[data-motion-slow]') ?? [])]) {
      toggle.setAttribute('aria-pressed', String(slow));
      toggle.title = slow ? 'Debug: animations at 10% speed. Click for normal speed.' : 'Debug: slow animations to 10% speed';
    }
  }
  // Delegated, for the same reason.
  document.addEventListener('click', e => {
    if (e.composedPath()[0]?.closest?.('[data-motion-slow]')) setSlow(scale === 1);
  });
  return {setSlow, get scale() { return scale; }, track, trackAnime, after, cancel};
})();
