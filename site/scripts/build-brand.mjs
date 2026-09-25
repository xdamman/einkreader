// Builds the brand kit served at einkreader.app/brand: every asset is drawn
// here as SVG (the source of truth), then rasterized to PNG — and JPG for
// the banners — so each download comes in a vector and a pixel format.
// Text is converted to outlines, so the SVGs render identically without the
// PT Serif font installed.
//
// Run from site/ (the renderer and font parser are not app dependencies):
//
//   npm i --no-save @resvg/resvg-js@2 opentype.js@1 jpeg-js@0.4
//   node scripts/build-brand.mjs
//
// Output: public/brand/* and public/brand/einkreader-brand-kit.zip, plus
// the site favicons and Open Graph image in public/.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Resvg } from '@resvg/resvg-js';
import opentype from 'opentype.js';
import jpeg from 'jpeg-js';
import JSZip from 'jszip';

const here = dirname(fileURLToPath(import.meta.url));
const pub = join(here, '..', 'public');
const out = join(pub, 'brand');
const fonts = join(here, '..', '..', 'test', 'screenshots', 'fonts');
mkdirSync(out, { recursive: true });

// ------------------------------------------------------------------ palette
// Warm, near-neutral greys: they read as intended in color and survive an
// e-ink panel's grayscale without losing contrast.
export const colors = {
  paper: '#EFEBE4', // icon background, banners
  screen: '#E1DDD6', // the device screen
  ink: '#434345', // device body, RSS symbol
  stone: '#8E8D8B', // list rows on the screen
  black: '#111111', // wordmark, text (matches the site)
  white: '#FFFFFF',
};
const c = colors;

// ------------------------------------------------------------------- text
const serifBold = opentype.parse(
  readFileSync(join(fonts, 'PTSerif-Bold.ttf')).buffer);
const serif = opentype.parse(
  readFileSync(join(fonts, 'PTSerif-Regular.ttf')).buffer);

/** Outlined text: a <path> plus its width, baseline at y. */
function text(str, { x = 0, y = 0, size, font = serifBold, fill = c.black }) {
  const path = font.getPath(str, x, y, size);
  return {
    svg: `<path fill="${fill}" d="${path.toPathData(2)}"/>`,
    width: font.getAdvanceWidth(str, size),
  };
}

// ------------------------------------------------------------------- mark
/**
 * The e-reader glyph (device + feed symbol + list rows) in a 1024 box,
 * drawn from the Android launcher icon. [scheme] 'light' is the default;
 * 'dark' is for dark backgrounds.
 */
function device(scheme = 'light') {
  const body = scheme === 'dark' ? c.paper : c.ink;
  const screen = scheme === 'dark' ? c.ink : c.screen;
  const symbol = scheme === 'dark' ? c.paper : c.ink;
  const rows = scheme === 'dark' ? '#B9B5AE' : c.stone;
  const bar = scheme === 'dark' ? '#6A6A6C' : '#CECAC2';
  const rowYs = [590, 660, 730];
  const rowLens = [300, 260, 280];
  return `
  <rect x="192" y="96" width="640" height="832" rx="76" fill="${body}"/>
  <rect x="256" y="176" width="512" height="624" rx="14" fill="${screen}"/>
  <rect x="452" y="848" width="120" height="28" rx="14" fill="${bar}"/>
  <circle cx="352" cy="468" r="34" fill="${symbol}"/>
  <path d="M318 364 A138 138 0 0 1 456 502 M318 266 A236 236 0 0 1 554 502"
        fill="none" stroke="${symbol}" stroke-width="50" stroke-linecap="round"/>
  ${rowYs.map((y, i) => `
  <rect x="318" y="${y}" width="40" height="40" rx="4" fill="${rows}"/>
  <rect x="384" y="${y + 13}" width="${rowLens[i]}" height="14" rx="7" fill="${rows}"/>`).join('')}`;
}

const svgDoc = (w, h, body) =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" ` +
  `viewBox="0 0 ${w} ${h}">${body}\n</svg>\n`;

/** The device glyph placed at (x, y) scaled to [size] px. */
const placeDevice = (x, y, size, scheme) =>
  `<g transform="translate(${x} ${y}) scale(${size / 1024})">${device(scheme)}</g>`;

// ------------------------------------------------------------------ assets
const assets = []; // { name, svg, png: [sizes] | [w], jpg?: bool, group }

function add(name, w, h, body, { group, png = [w], jpg = false, label }) {
  assets.push({ name, w, h, svg: svgDoc(w, h, body), png, jpg, group, label });
}

// App icon: paper tile with rounded corners, as on the home screen.
add('icon', 1024, 1024,
  `<rect width="1024" height="1024" rx="228" fill="${c.paper}"/>${device()}`,
  { group: 'icon', png: [1024, 512, 192], label: 'App icon' });

// Square icon without rounded corners: for places that apply their own
// mask (Play Store, social avatars).
add('icon-square', 1024, 1024,
  `<rect width="1024" height="1024" fill="${c.paper}"/>` +
  placeDevice(112, 112, 800),
  { group: 'icon', png: [1024, 512], label: 'App icon, square (unmasked)' });

// Mark alone on a transparent background.
add('mark', 1024, 1024, device(),
  { group: 'logo', png: [1024, 256], label: 'Mark' });
add('mark-dark-bg', 1024, 1024, device('dark'),
  { group: 'logo', png: [1024, 256], label: 'Mark for dark backgrounds' });

// Wordmark, horizontal and stacked lockups — sized from measured ink
// bounds (not font metrics) with even padding, so nothing touches an edge.
{
  // The device's visible extent inside its 1024 box.
  const dev = { x: 192, y: 96, w: 640, h: 832 };
  /** Device scaled so its visible height is [h], top-left of ink at (x, y). */
  const deviceAt = (x, y, h, scheme) => {
    const s = h / dev.h;
    return placeDevice(x - dev.x * s, y - dev.y * s, 1024 * s, scheme);
  };
  const deviceW = (h) => (dev.w / dev.h) * h;

  const size = 200;
  const bounds = serifBold.getPath('einkreader', 0, 0, size).getBoundingBox();
  const inkW = bounds.x2 - bounds.x1;
  const inkH = bounds.y2 - bounds.y1; // ascender top to baseline
  /** Wordmark with its ink box's top-left at (x, y). */
  const wordAt = (x, y, fill = c.black) =>
    text('einkreader', { x: x - bounds.x1, y: y - bounds.y1, size, fill }).svg;

  const pad = 24;
  const ww = Math.ceil(inkW + 2 * pad);
  const wh = Math.ceil(inkH + 2 * pad);
  add('wordmark', ww, wh, wordAt(pad, pad),
    { group: 'logo', label: 'Wordmark' });
  add('wordmark-white', ww, wh, wordAt(pad, pad, c.white),
    { group: 'logo', label: 'Wordmark, white' });

  // Horizontal: the device is 1.6× the wordmark's height, text centered on
  // it, gap = a third of the device height.
  const markH = Math.round(inkH * 1.6);
  const gap = Math.round(markH / 3);
  const hw = Math.ceil(pad + deviceW(markH) + gap + inkW + pad);
  const hh = markH + 2 * pad;
  const hLogo = (scheme, fill) =>
    deviceAt(pad, pad, markH, scheme) +
    wordAt(pad + deviceW(markH) + gap, pad + (markH - inkH) / 2, fill);
  add('logo-horizontal', hw, hh, hLogo('light', c.black),
    { group: 'logo', png: [hw * 2, hw], label: 'Horizontal logo' });
  add('logo-horizontal-white', hw, hh, hLogo('dark', c.white),
    { group: 'logo', png: [hw * 2, hw],
      label: 'Horizontal logo, for dark backgrounds' });

  // Stacked: device above the wordmark, centered.
  const stackH = Math.round(inkH * 2.4);
  const sw = Math.ceil(inkW + 2 * pad);
  const sh = Math.ceil(pad + stackH + inkH * 0.5 + inkH + pad);
  add('logo-stacked', sw, sh,
    deviceAt((sw - deviceW(stackH)) / 2, pad, stackH) +
    wordAt(pad, pad + stackH + inkH * 0.5),
    { group: 'logo', png: [sw * 2, sw], label: 'Stacked logo' });
}

// Banners: paper background, mark + wordmark + tagline, centered.
const tagline = 'A calm, offline-first reading app for e-ink tablets.';
function banner(w, h, { markSize, wordSize, tagSize, gap = 0.08 }) {
  const word = text('einkreader', { size: wordSize });
  const tag = text(tagline, { size: tagSize, font: serif });
  const blockW = markSize + wordSize * 0.25 + Math.max(word.width, tag.width);
  const x0 = (w - blockW) / 2;
  const tx = x0 + markSize + wordSize * 0.25;
  const blockH = markSize;
  const y0 = (h - blockH) / 2;
  return `<rect width="${w}" height="${h}" fill="${c.paper}"/>` +
    placeDevice(x0, y0, markSize) +
    text('einkreader', { x: tx, y: y0 + markSize * 0.56, size: wordSize }).svg +
    text(tagline, {
      x: tx, y: y0 + markSize * 0.56 + tagSize * 1.9, size: tagSize,
      font: serif, fill: c.ink,
    }).svg;
}
add('og-image', 1200, 630,
  banner(1200, 630, { markSize: 300, wordSize: 120, tagSize: 30 }),
  { group: 'banner', jpg: true, label: 'Link preview (Open Graph) · 1200×630' });
add('x-header', 1500, 500,
  banner(1500, 500, { markSize: 260, wordSize: 124, tagSize: 32 }),
  { group: 'banner', jpg: true, label: 'X / Twitter header · 1500×500' });
add('linkedin-cover', 1584, 396,
  banner(1584, 396, { markSize: 220, wordSize: 104, tagSize: 27 }),
  { group: 'banner', jpg: true, label: 'LinkedIn cover · 1584×396' });
add('play-feature-graphic', 1024, 500,
  banner(1024, 500, { markSize: 230, wordSize: 92, tagSize: 22 }),
  { group: 'banner', jpg: true, label: 'Google Play feature graphic · 1024×500' });

// Social avatar: the square icon (platforms crop it to a circle; the
// device sits well inside the circle's safe zone).
add('avatar', 400, 400,
  `<rect width="400" height="400" fill="${c.paper}"/>` +
  placeDevice(60, 60, 280),
  { group: 'social', png: [400, 800], jpg: true,
    label: 'Profile picture · 400×400' });

// ----------------------------------------------------------------- render
function png(svg, width) {
  return new Resvg(svg, { fitTo: { mode: 'width', value: width } })
    .render().asPng();
}

/** JPG at the asset's own size (banners and avatars are opaque). */
function jpg(svg, width) {
  const img = new Resvg(svg, { fitTo: { mode: 'width', value: width } })
    .render();
  return jpeg.encode(
    { data: img.pixels, width: img.width, height: img.height }, 92).data;
}

const zip = new JSZip();
const manifest = [];
for (const a of assets) {
  const files = [];
  writeFileSync(join(out, `${a.name}.svg`), a.svg);
  files.push({ format: 'SVG', file: `${a.name}.svg` });
  for (const width of a.png) {
    const suffix =
      width === a.w ? '' : width === 2 * a.w ? '@2x' : `-${width}`;
    const file = `${a.name}${suffix}.png`;
    writeFileSync(join(out, file), png(a.svg, width));
    files.push({
      format: 'PNG',
      file,
      size: `${width}×${Math.round((a.h * width) / a.w)}`,
    });
  }
  if (a.jpg) {
    writeFileSync(join(out, `${a.name}.jpg`), jpg(a.svg, a.w));
    files.push({ format: 'JPG', file: `${a.name}.jpg`, size: `${a.w}×${a.h}` });
  }
  for (const f of files) {
    zip.file(`einkreader-brand/${f.file}`, readFileSync(join(out, f.file)));
  }
  manifest.push({ name: a.name, label: a.label, group: a.group, w: a.w, h: a.h, files });
}
writeFileSync(join(out, 'manifest.json'), JSON.stringify(manifest, null, 2));

// Site favicons + Open Graph image.
const iconSvg = assets.find((a) => a.name === 'icon').svg;
writeFileSync(join(pub, 'favicon.svg'), iconSvg);
writeFileSync(join(pub, 'favicon-32.png'), png(iconSvg, 32));
writeFileSync(join(pub, 'apple-touch-icon.png'),
  png(assets.find((a) => a.name === 'icon-square').svg, 180));

writeFileSync(join(pub, 'og-image.png'),
  png(assets.find((a) => a.name === 'og-image').svg, 1200));

// Download cards on /brand, filled between <!-- assets:group --> markers so
// the page always lists exactly what was generated.
const escape = (t) => t.replace(/&/g, '&amp;').replace(/</g, '&lt;');
function card(entry) {
  const dark = /white|dark-bg/.test(entry.name);
  const svg = entry.files.find((f) => f.format === 'SVG');
  const links = entry.files.map((f) =>
    `<a href="/brand/${f.file}" download>${f.format}</a>` +
    (f.size ? ` <span>${f.size}</span>` : '')).join('\n          ');
  return `
      <div class="card">
        <div class="preview${dark ? ' dark' : ''}"><img src="/brand/${svg.file}" alt="${escape(entry.label)}" loading="lazy"></div>
        <div class="meta">
          <div class="label">${escape(entry.label)}</div>
          <div class="files">
          ${links}
          </div>
        </div>
      </div>`;
}
const pagePath = join(pub, 'brand.html');
let page = readFileSync(pagePath, 'utf8');
for (const group of ['logo', 'icon', 'social', 'banner']) {
  const cards = manifest.filter((m) => m.group === group).map(card).join('');
  const grid = `<div class="grid${group === 'banner' ? ' wide' : ''}">${cards}
      </div>`;
  page = page.replace(
    new RegExp(`<!-- assets:${group} -->[\\s\\S]*?<!-- /assets:${group} -->`),
    `<!-- assets:${group} -->${grid}<!-- /assets:${group} -->`);
}
writeFileSync(pagePath, page);

writeFileSync(join(out, 'einkreader-brand-kit.zip'),
  await zip.generateAsync({ type: 'nodebuffer', compression: 'DEFLATE' }));
console.log(`${assets.length} assets written to ${out}`);
