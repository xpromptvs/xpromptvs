/** Animate a moving color bar on the canvas and return a captured video stream. */
export function startTestPattern(canvas: HTMLCanvasElement): MediaStream {
  const ctx = canvas.getContext("2d")!;
  let t = 0;
  const draw = () => {
    const w = canvas.width;
    const h = canvas.height;
    ctx.fillStyle = "#202830";
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = `hsl(${t % 360}, 70%, 55%)`;
    ctx.fillRect((t * 3) % w, 0, 40, h);
    ctx.fillStyle = "#fff";
    ctx.font = "16px monospace";
    ctx.fillText(`rdev test pattern ${t}`, 10, 24);
    t++;
  };
  setInterval(draw, 100);
  return canvas.captureStream(10);
}
