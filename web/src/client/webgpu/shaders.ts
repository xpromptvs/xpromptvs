/// The WebGPU terminal's three passes, one draw each, instanced ONE PER CELL (`instance_index` is the cell,
/// row-major) and reading storage buffers rather than vertex attributes (renderer.ts fills them):
///
/// - **backgrounds** — a cell's non-default background (alpha 0 is the default: no quad), its outer
///   corners rounded where the cell's flags say (renderer.ts `corners`) and, EXPERIMENTAL, the diff's green and red
///   blended between their stored top and bottom colours by where the pixel sits in the terminal area, dithered
///   (`blend`, webgpu/gradient.ts);
/// - **glyphs** — the cell's atlas bitmap at its offset, fetched texel for texel (`textureLoad`: glyphs sit
///   on whole device pixels, so nothing is resampled), tinted with the cell's colour unless it is a colour
///   glyph;
/// - **lines** — underline (five styles), strikethrough, overline and the non-block cursors, drawn per
///   pixel from the cell's flags (cell-model.ts `Flag`) — no texture.
///
/// Column x positions come from `colX` (cols + 1 whole device px): cells are as wide as the DOM renderer's,
/// fractional, and JS and the shader must agree to the pixel on where each starts.
/// Colours are 0xRRGGBBAA; output is premultiplied (blend `one`, `one-minus-src-alpha`).
export const TERMINAL_WGSL = /* wgsl */ `
struct U {
  canvas: vec2f,
  cellH: f32,
  originY: f32,
  cols: u32,
  rows: u32,
  thickness: f32,
  underlineY: f32,
  strikeY: f32,
  curlyAmp: f32,
  cursorColor: u32,
  barWidth: f32,
  radius: f32,
  dpr: f32,
  originX: f32,
  // The area's height in device px: the canvas's y = 0 is its top.
  areaH: f32,
  // The gradient's stored colours, HSL (x hue in turns, y saturation, z lightness): the diff green's and red's at
  // the area's top edge and at its bottom edge. greenTop.w: the gradient is on; greenBottom.w: it is dithered.
  greenTop: vec4f,
  greenBottom: vec4f,
  redTop: vec4f,
  redBottom: vec4f,
};

@group(0) @binding(0) var<uniform> u: U;
@group(0) @binding(1) var<storage, read> colX: array<u32>;
// Per cell: background, flags, line colour (strike/overline), underline colour.
@group(0) @binding(2) var<storage, read> cells: array<vec4u>;
// Per cell: atlas x | y << 16, w | h << 16 | colour << 31, left | top << 16 (signed), colour.
@group(0) @binding(3) var<storage, read> glyphs: array<vec4u>;
@group(0) @binding(4) var atlas: texture_2d<f32>;

fn corner(v: u32) -> vec2f {
  var c = array<vec2f, 6>(vec2f(0.0, 0.0), vec2f(1.0, 0.0), vec2f(0.0, 1.0),
                          vec2f(0.0, 1.0), vec2f(1.0, 0.0), vec2f(1.0, 1.0));
  return c[v];
}
fn clip(p: vec2f) -> vec4f {
  return vec4f(p.x / u.canvas.x * 2.0 - 1.0, 1.0 - p.y / u.canvas.y * 2.0, 0.0, 1.0);
}
fn unpack(c: u32) -> vec4f {
  return vec4f(f32((c >> 24u) & 255u), f32((c >> 16u) & 255u), f32((c >> 8u) & 255u), f32(c & 255u)) / 255.0;
}
fn premul(c: vec4f) -> vec4f { return vec4f(c.rgb * c.a, c.a); }
fn cellOrigin(i: u32) -> vec2f {
  let col = i % u.cols;
  let row = i / u.cols;
  return vec2f(u.originX + f32(colX[col]), u.originY + f32(row) * u.cellH);
}
const OFF = vec4f(2.0, 2.0, 0.0, 1.0);

// ---------------------------------------------------------------------------------- backgrounds
// A cell's rounded corners (cell-model.ts Flag.CORNER_*): an antialiased arc of u.radius, scaled down to
// half the cell when the cell is narrower than that (as CSS scales a border-radius to fit).
struct BgOut {
  @builtin(position) pos: vec4f,
  @location(0) @interpolate(flat) color: u32,
  @location(1) local: vec2f,
  @location(2) @interpolate(flat) size: vec2f,
  @location(3) @interpolate(flat) mask: u32,
};
@vertex fn bgVs(@builtin(vertex_index) v: u32, @builtin(instance_index) i: u32) -> BgOut {
  var o: BgOut;
  let c = cells[i];
  if ((c.x & 255u) == 0u) { o.pos = OFF; return o; }
  let col = i % u.cols;
  let p0 = cellOrigin(i);
  let size = vec2f(f32(colX[col + 1u]) - f32(colX[col]), u.cellH);
  let k = corner(v);
  o.pos = clip(p0 + k * size);
  o.color = c.x;
  o.local = k * size;
  o.size = size;
  // The corners (Flag.CORNER_*, bits 0-3 here) and the gradient it takes (Flag.GRADIENT_*, bits 4-5: 1 green, 2 red).
  o.mask = (c.y >> 10u) & 63u;
  return o;
}
fn arc(p: vec2f, centre: vec2f, r: f32) -> f32 { return clamp(r - distance(p, centre) + 0.5, 0.0, 1.0); }

// EXPERIMENTAL — THE GRADIENT IS THE AREA'S, NOT THE BLOCK'S (as iMessage's bubbles): a cell of the diff's green
// or red is drawn as the blend of that colour's stored top and bottom colours by where the pixel sits in the
// terminal area — top edge to bottom edge, in HSL, the hue the short way round — so a block is one colour near
// the top of the screen and another near the bottom, and a line changes as it scrolls. DITHERED: a block spans
// only some twenty 8-bit levels from top to bottom, so undithered it shows bands; half a level of noise, fixed
// to the screen's pixels (interleaved gradient noise), mixes each band into the next.
fn fromHsl(c: vec3f) -> vec3f {
  let k = (vec3f(0.0, 8.0, 4.0) + c.x * 12.0) % 12.0;
  let a = c.y * min(c.z, 1.0 - c.z);
  return c.z - a * clamp(min(k - 3.0, 9.0 - k), vec3f(-1.0), vec3f(1.0));
}
fn blend(a: vec4f, b: vec4f, t: f32) -> vec3f {
  let dh = (b.x - a.x) - round(b.x - a.x);
  return vec3f(fract(a.x + dh * t), mix(a.yz, b.yz, t));
}
// Interleaved gradient noise (Jimenez): uniform in [0, 1), stable per pixel, no visible pattern.
fn dither(p: vec2f) -> f32 { return fract(52.9829189 * fract(dot(floor(p), vec2f(0.06711056, 0.00583715)))); }

// Shared by the background and glyph passes so the tint follows the painted gradient exactly.
fn backgroundRgb(color: u32, slot: u32, pos: vec2f) -> vec3f {
  var rgb = unpack(color).rgb;
  if (slot != 0u && u.greenTop.w != 0.0 && u.areaH > 0.0) {
    let t = clamp(pos.y / u.areaH, 0.0, 1.0);
    rgb = fromHsl(select(blend(u.redTop, u.redBottom, t), blend(u.greenTop, u.greenBottom, t), slot == 1u));
    if (u.greenBottom.w != 0.0) { rgb = clamp(rgb + (dither(pos) - 0.5) / 255.0, vec3f(0.0), vec3f(1.0)); }
  }
  return rgb;
}

@fragment fn bgFs(in: BgOut) -> @location(0) vec4f {
  var cov = 1.0;
  if ((in.mask & 15u) != 0u) {
    let r = min(u.radius, min(in.size.x, in.size.y) * 0.5);
    let p = in.local;
    let w = in.size.x;
    let h = in.size.y;
    if ((in.mask & 1u) != 0u && p.x < r && p.y < r) { cov = min(cov, arc(p, vec2f(r, r), r)); }
    if ((in.mask & 2u) != 0u && p.x > w - r && p.y < r) { cov = min(cov, arc(p, vec2f(w - r, r), r)); }
    if ((in.mask & 4u) != 0u && p.x > w - r && p.y > h - r) { cov = min(cov, arc(p, vec2f(w - r, h - r), r)); }
    if ((in.mask & 8u) != 0u && p.x < r && p.y > h - r) { cov = min(cov, arc(p, vec2f(r, h - r), r)); }
  }
  let c = unpack(in.color);
  let a = c.a * cov;
  if (a <= 0.0) { discard; }
  let rgb = backgroundRgb(in.color, (in.mask >> 4u) & 3u, in.pos.xy);
  return vec4f(rgb * a, a);
}

// --------------------------------------------------------------------------------------- glyphs
struct GlyphOut {
  @builtin(position) pos: vec4f,
  @location(0) texel: vec2f,
  @location(1) @interpolate(flat) color: u32,
  @location(2) @interpolate(flat) isColor: u32,
  @location(3) @interpolate(flat) background: u32,
  @location(4) @interpolate(flat) gradient: u32,
};
@vertex fn glyphVs(@builtin(vertex_index) v: u32, @builtin(instance_index) i: u32) -> GlyphOut {
  var o: GlyphOut;
  let g = glyphs[i];
  let w = g.y & 0xffffu;
  let h = (g.y >> 16u) & 0x7fffu;
  if (w == 0u) { o.pos = OFF; return o; }
  let offset = vec2f(f32(bitcast<i32>(g.z << 16u) >> 16u), f32(bitcast<i32>(g.z) >> 16u));
  let size = vec2f(f32(w), f32(h));
  let k = corner(v);
  o.pos = clip(cellOrigin(i) + offset + k * size);
  o.texel = vec2f(f32(g.x & 0xffffu), f32(g.x >> 16u)) + k * size;
  o.color = g.w;
  o.isColor = g.y >> 31u;
  o.background = cells[i].x;
  o.gradient = (cells[i].y >> 14u) & 3u;
  return o;
}
// Increase brightness separation from the background, then add a restrained amount of its chroma.
// Limit the tint as a whole near black/white, rather than clipping channels and shifting brightness.
fn tintGray(base: vec3f, gray: f32) -> vec3f {
  let brightness = dot(base, vec3f(0.2126, 0.7152, 0.0722));
  let contrasted = clamp(brightness + 1.56 * (gray - brightness), 0.0, 1.0);
  let chroma = base - brightness;
  let low = min(chroma.r, min(chroma.g, chroma.b));
  let high = max(chroma.r, max(chroma.g, chroma.b));
  let strength = min(0.35, min(contrasted / max(-low, 0.00001), (1.0 - contrasted) / max(high, 0.00001)));
  return vec3f(contrasted) + strength * chroma;
}
fn linearRgb(c: vec3f) -> vec3f {
  return select(pow((c + 0.055) / 1.055, vec3f(2.4)), c / 12.92, c <= vec3f(0.04045));
}
fn readableColor(source: vec3f, base: vec3f) -> vec3f {
  let weights = vec3f(0.2126, 0.7152, 0.0722);
  let ink = linearRgb(source);
  let fg = dot(ink, weights);
  let bg = dot(linearRgb(base), weights);
  if ((max(fg, bg) + 0.05) / (min(fg, bg) + 0.05) >= 3.25) { return source; }
  // Mix only as far as needed toward white (dark backgrounds) or black (light ones).
  // Linear-light mixing preserves the source's channel proportions without clipping.
  let lighter = (bg + 0.05) * 3.25 - 0.05;
  let targetLuminance = select(max(0.0, (bg + 0.05) / 3.25 - 0.05), lighter, lighter <= 1.0);
  let end = select(0.0, 1.0, lighter <= 1.0);
  let amount = clamp((targetLuminance - fg) / (end - fg), 0.0, 1.0);
  let result = mix(ink, vec3f(end), amount);
  return select(1.055 * pow(result, vec3f(1.0 / 2.4)) - 0.055, result * 12.92, result <= vec3f(0.0031308));
}
@fragment fn glyphFs(in: GlyphOut) -> @location(0) vec4f {
  let t = textureLoad(atlas, vec2i(floor(in.texel)), 0);
  if (in.isColor != 0u) { return t; }
  let c = unpack(in.color);
  let a = c.a * t.a;
  var rgb = c.rgb;
  let bg = backgroundRgb(in.background, in.gradient, in.pos.xy);
  if ((in.background & 255u) != 0u && c.r == c.g && c.g == c.b && (bg.r != bg.g || bg.g != bg.b)) {
    rgb = tintGray(bg, c.r);
  } else if ((in.background & 255u) != 0u && (bg.r != bg.g || bg.g != bg.b)) {
    rgb = readableColor(c.rgb, bg);
  }
  return vec4f(rgb * a, a);
}

// ---------------------------------------------------------------------------------------- lines
struct LineOut {
  @builtin(position) pos: vec4f,
  @location(0) local: vec2f,
  @location(1) @interpolate(flat) size: vec2f,
  @location(2) @interpolate(flat) flags: u32,
  @location(3) @interpolate(flat) lineColor: u32,
  @location(4) @interpolate(flat) underlineColor: u32,
};
@vertex fn lineVs(@builtin(vertex_index) v: u32, @builtin(instance_index) i: u32) -> LineOut {
  var o: LineOut;
  let c = cells[i];
  if ((c.y & 0xffu) == 0u) { o.pos = OFF; return o; }
  let col = i % u.cols;
  let span = max(1u, (c.y >> 8u) & 3u);
  let end = min(col + span, u.cols);
  let p0 = cellOrigin(i);
  let size = vec2f(f32(colX[end]) - f32(colX[col]), u.cellH);
  let k = corner(v);
  o.pos = clip(p0 + k * size);
  o.local = k * size;
  o.size = size;
  o.flags = c.y;
  o.lineColor = c.z;
  o.underlineColor = c.w;
  return o;
}
fn band(y: f32, top: f32, t: f32) -> f32 { return select(0.0, 1.0, y >= top && y < top + t); }
fn over(dst: vec4f, c: vec4f, cov: f32) -> vec4f {
  let a = c.a * cov;
  return vec4f(c.rgb * a, a) + dst * (1.0 - a);
}
@fragment fn lineFs(in: LineOut) -> @location(0) vec4f {
  let x = in.pos.x;
  let y = in.local.y;
  let t = u.thickness;
  var out = vec4f(0.0);
  let style = in.flags & 7u;
  if (style != 0u) {
    let y0 = u.underlineY;
    var cov = 0.0;
    if (style == 1u) { cov = band(y, y0, t); }
    else if (style == 2u) { cov = max(band(y, y0 - t, t), band(y, y0 + t, t)); }
    else if (style == 3u) {
      let period = max(6.0 * t, 4.0 * u.dpr);
      let cy = y0 + u.curlyAmp * sin(x / period * 6.2831853);
      cov = clamp(t * 0.75 - abs(y - cy) + 0.5, 0.0, 1.0);
    }
    else if (style == 4u) { cov = band(y, y0, t) * select(0.0, 1.0, fract(x / (2.0 * t)) < 0.5); }
    else { cov = band(y, y0, t) * select(0.0, 1.0, fract(x / (6.0 * t)) < 0.5); }
    out = over(out, unpack(in.underlineColor), cov);
  }
  if ((in.flags & 8u) != 0u) { out = over(out, unpack(in.lineColor), band(y, u.strikeY, t)); }
  if ((in.flags & 16u) != 0u) { out = over(out, unpack(in.lineColor), band(y, 0.0, t)); }
  let cursor = (in.flags >> 5u) & 7u;
  if (cursor != 0u) {
    let lx = in.local.x;
    let ct = max(1.0, floor(u.dpr));
    var cov = 0.0;
    if (cursor == 1u) { cov = select(0.0, 1.0, y >= in.size.y - ct); }
    else if (cursor == 2u) { cov = select(0.0, 1.0, lx < u.barWidth); }
    else { cov = select(0.0, 1.0, lx < ct || lx >= in.size.x - ct || y < ct || y >= in.size.y - ct); }
    out = over(out, unpack(u.cursorColor), cov);
  }
  if (out.a <= 0.0) { discard; }
  return out;
}
`;
