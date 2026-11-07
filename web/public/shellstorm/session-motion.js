// Slide the session into its fixed final position using compositor-friendly WAAPI.
const SessionMotion = (() => {
  const session = document.querySelector('#session');
  if (!session) return {open:callback=>callback?.(), close:callback=>callback?.(), finish() {}, retint() {}};
  const query = selector => session.querySelector('[data-client-host]')?.shadowRoot?.querySelector(selector) ?? document.querySelector(selector);
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const tintTargets = [document.querySelector('.safari-tint'), document.documentElement, document.body].filter(Boolean);
  const theme = document.querySelector('meta[name="theme-color"]');
  let tintAnimation, untrackTint, targetColor, tintSource;
  let animation, untrack, onClosed, prepareFrame, startFrame;
  // Re-sample `tintSource`'s CURRENT background and re-apply it. `finish()` below only ever paints
  // the colour it sampled at the START of the slide it is finishing, so a theme change with no slide
  // to carry it — toggling after the slide has settled — left the tint targets and the meta tag at
  // the OLD theme's colour until the next slide happened to resample them (Safari's toolbar tint,
  // since the three bands cover the page itself). A no-op before the first slide, when there is
  // nothing yet to re-sample and CSS alone is still carrying the tint.
  function retint() {
    if (!tintSource) return;
    const el = query(tintSource) ?? document.querySelector('.ss-header');
    if (!el) return;
    targetColor = getComputedStyle(el).backgroundColor;
    tintTargets.forEach(target => { target.style.backgroundColor = targetColor; });
    if (theme) theme.content = targetColor;
  }
  function finish() {
    cancelAnimationFrame(prepareFrame);
    cancelAnimationFrame(startFrame);
    untrackTint?.();
    untrackTint = null;
    tintAnimation?.cancel();
    tintAnimation = null;
    if (targetColor) {
      tintTargets.forEach(target => { target.style.backgroundColor = targetColor; });
      if (theme) theme.content = targetColor;
    }
    const callback = onClosed;
    onClosed = null;
    callback?.();
    untrack?.();
    untrack = null;
    animation?.cancel();
    animation = null;
    session.style.removeProperty('transform');
    session.style.removeProperty('will-change');
  }
  function slide(closing, callback) {
    finish();
    onClosed = callback;
    tintSource = closing ? '.ss-header' : '#tabbar';
    targetColor = getComputedStyle(query(tintSource) ?? document.querySelector('.ss-header')).backgroundColor;
    if (reduced.matches || document.hidden) { finish(); return; }
    session.style.willChange = 'transform';
    // Give Safari a painted compositing layer before starting the motion.
    const travel = session.getBoundingClientRect().height;
    const offscreen = `translate3d(0, ${travel}px, 0)`;
    const start = closing ? 'translate3d(0, 0, 0)' : offscreen;
    const end = closing ? offscreen : 'translate3d(0, 0, 0)';
    session.style.transform = start;
    const begin = () => {
      const options = {duration:closing ? 250 : 400, ease:closing ? 'cubic-bezier(0.42, 0.0, 0.58, 1.0)' : 'cubic-bezier(0.23, 1.0, 0.32, 1.0)', onComplete:finish};
      // Animate the sampler's actual background; metadata is an older-browser fallback.
      if (theme) theme.content = targetColor;
      tintAnimation = anime.animate(tintTargets, {
        backgroundColor:targetColor, duration:options.duration, ease:options.ease
      });
      untrackTint = MotionDebug.trackAnime(tintAnimation);
      if (typeof session.animate === 'function' && anime.waapi?.animate) {
        animation = anime.waapi.animate(session, {...options, transform:[start, end]});
      } else {
        session.style.removeProperty('transform');
        animation = anime.animate(session, {...options, translateY:closing ? ['0px', `${travel}px`] : [`${travel}px`, '0px']});
      }
      untrack = MotionDebug.trackAnime(animation);
    };
    if (closing) begin();
    else prepareFrame = requestAnimationFrame(() => { startFrame = requestAnimationFrame(begin); });

  }
  // Interaction can settle the surface immediately without waiting for the reveal.
  session.addEventListener('pointerdown', finish, {capture:true, passive:true});
  session.addEventListener('keydown', finish, {capture:true});
  reduced.addEventListener('change', finish);
  document.addEventListener('visibilitychange', () => { if (document.hidden) finish(); });
  return {open:callback => slide(false, callback), close:callback => slide(true, callback), finish, retint};
})();
