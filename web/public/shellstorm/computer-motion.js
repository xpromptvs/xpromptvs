// A brief screen ignition, followed by a gently breathing halo while connecting.
const ComputerMotion = (() => {
  const running = new Set();
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  function finishAll() { for (const finish of [...running]) finish(); }
  function capture() {
    return new Map([...document.querySelectorAll('.device-card')].map(row => {
      const light = row.querySelector('.computer-screen-light');
      const glow = row.querySelector('.computer-screen-glow');
      return [row.dataset.deviceId, {light:+getComputedStyle(light).opacity,
        glow:+getComputedStyle(glow).opacity,
        scale:new DOMMatrixReadOnly(getComputedStyle(glow).transform).a}];
    }));
  }
  function start(row, reduceMotion, lit, previous) {
    if (reduceMotion || reduced.matches || document.hidden) return;
    const light = row.querySelector('.computer-screen-light');
    const glow = row.querySelector('.computer-screen-glow');
    if (!lit && (!previous || (!previous.light && !previous.glow))) return;
    const resume = previous && (previous.light > 0 || previous.glow > 0);
    const screenAnimation = anime.animate(light, {
      opacity: !lit ? {from:previous.light, to:0, duration:300, ease:'outQuad'} : resume ? {from:previous.light, to:1, duration:150, ease:'outQuad'} : [
        {from:0, to:.75, duration:25, ease:'steps(1)'},
        {to:.25, duration:30, ease:'steps(1)'},
        {to:1, duration:280, ease:'outQuad'}
      ]
    });
    const glowAnimation = anime.animate(glow, {
      opacity:{from:resume ? previous.glow : 0, to:lit ? .6333 : 0},
      delay:0, duration:lit ? 500 : 300, ease:'outQuad'
    });
    const untrack = [screenAnimation, glowAnimation].map(MotionDebug.trackAnime);
    let breathing, stopped = false;
    function finish() {
      stopped = true;
      breathing?.cancel();
      untrack.forEach(stop => stop());
      screenAnimation.cancel();
      glowAnimation.cancel();
      light.style.removeProperty('opacity');
      glow.style.removeProperty('opacity');
      glow.style.removeProperty('transform');
      running.delete(finish);
    }
    running.add(finish);
    glowAnimation.then(() => {
      if (stopped || !row.isConnected) return;
      if (!lit) { finish(); return; }
      breathing = anime.animate(glow, {
        opacity:{from:.6333, to:.54},
        duration:900, ease:'inOutSine', alternate:true, loop:true
      });
      untrack.push(MotionDebug.trackAnime(breathing));
    });
  }
  reduced.addEventListener('change', finishAll);
  document.addEventListener('visibilitychange', () => { if (document.hidden) finishAll(); });
  return {start, finishAll, capture};
})();
