/* Render soft rectangular halos once. Animation only changes composited opacity. */
const GlowRaster = (() => {
  const cache = new Map();
  function erf(x) {
    const sign = x < 0 ? -1 : 1;
    x = Math.abs(x);
    const t = 1 / (1 + .3275911 * x);
    return sign * (1 - (((((1.061405429*t - 1.453152027)*t) + 1.421413741)*t - .284496736)*t + .254829592)*t * Math.exp(-x*x));
  }
  function sprite(width, height, sigma, ink = 255) {
    const key = [width,height,sigma,ink].join(':');
    if (cache.has(key)) return cache.get(key);
    const pad = Math.ceil(sigma * 4), scale = 4;
    const canvas = document.createElement('canvas');
    canvas.width = Math.ceil((width + pad * 2) * scale);
    canvas.height = Math.ceil((height + pad * 2) * scale);
    const context = canvas.getContext('2d');
    const pixels = context.createImageData(canvas.width, canvas.height);
    const spread = sigma * Math.SQRT2;
    for (let y = 0; y < canvas.height; y++) {
      const py = (y + .5) / scale - pad;
      const ay = .5 * (erf(py / spread) - erf((py-height) / spread));
      for (let x = 0; x < canvas.width; x++) {
        const px = (x + .5) / scale - pad;
        const ax = .5 * (erf(px / spread) - erf((px-width) / spread));
        const i = (y * canvas.width + x) * 4;
        pixels.data[i] = pixels.data[i+1] = pixels.data[i+2] = ink;
        pixels.data[i+3] = Math.round(255 * ax * ay);
      }
    }
    context.putImageData(pixels, 0, 0);
    const result = {url:canvas.toDataURL(), pad, width:width+pad*2, height:height+pad*2};
    cache.set(key, result);
    return result;
  }
  return {sprite};
})();
