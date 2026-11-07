// Connection copy changes immediately. Keep button widths stable without text effects.
const ConnectionMotion = (() => {
  function status(element, text) {
    if (!element) return;
    element.textContent = text;
    element.setAttribute('aria-label', text);
  }
  function sizeButton(button) {
    const style = getComputedStyle(button);
    const context = document.createElement('canvas').getContext('2d');
    context.font = `${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
    const width = Math.ceil(Math.max(...[button.textContent.trim(),'Connect','Cancel'].map(text => context.measureText(text).width))
      + parseFloat(style.paddingLeft) + parseFloat(style.paddingRight)
      + parseFloat(style.borderLeftWidth) + parseFloat(style.borderRightWidth));
    button.dataset.fixedConnect = '';
    button.style.minWidth = button.style.maxWidth = `${width}px`;
  }
  function setConnecting(button) {
    const label = document.createElement('span');
    label.className = 'connection-label';
    label.textContent = button.hasAttribute('data-fixed-connect') ? 'Cancel' : 'Connecting…';
    label.setAttribute('aria-hidden', 'true');
    if (button.hasAttribute('data-fixed-connect')) { button.replaceChildren(label); return; }
    const cross = document.createElement('span');
    cross.className = 'connection-cancel';
    cross.innerHTML = '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="m5 5 14 14M19 5 5 19" stroke="currentColor" stroke-width="3" stroke-linecap="round"/></svg>';
    cross.setAttribute('aria-hidden', 'true');
    button.replaceChildren(label, cross);
  }
  return {
    sizeButton, setConnecting, status,
    finishAll() {}, run() {}, captureReturn() { return null; }, returnToIdle() {},
  };
})();
