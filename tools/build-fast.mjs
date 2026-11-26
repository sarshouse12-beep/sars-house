// Builds fast.html = index.html with Tailwind pre-compiled (no cdn.tailwindcss.com runtime).
// Usage: node tools/build-fast.mjs   (needs Tailwind v4 core + esbuild; paths overridable via TW_DIR / ESBUILD)
import fs from 'fs';
const TW = process.env.TW_DIR || '/opt/npm-tools/node_modules/tailwindcss/';
const { compile } = await import(TW + 'dist/lib.mjs');
const esbuild = await import(process.env.ESBUILD || '/opt/npm-tools/node_modules/esbuild/lib/main.js');
const html = fs.readFileSync('index.html', 'utf8');

// 1. candidates: every run of non-space/quote characters in the source
const cand = new Set();
for (const m of html.matchAll(/[^\s"'`]+/g)) { cand.add(m[0]); for (const p of m[0].split(/[;,{}=]/)) if (p) cand.add(p); }
for (const m of html.matchAll(/\$\{|\}/g)) { /* ignore */ }

// 2. compile (v3-compatible defaults layered on top of v4)
const input = `@import "tailwindcss";
@theme { --radius-sm: 0.125rem; --shadow-sm: 0 1px 2px 0 rgb(0 0 0 / 0.05); }
@layer base {
  *, ::after, ::before, ::backdrop, ::file-selector-button { border-color: #e5e7eb; }
  input::placeholder, textarea::placeholder { color: #9ca3af; }
  button:not(:disabled), [role="button"]:not(:disabled) { cursor: pointer; }
}`;
const c = await compile(input, { base: TW, loadStylesheet: async (id) => {
  const p = id === 'tailwindcss' ? TW + 'index.css' : id.startsWith('tailwindcss/') ? TW + id.slice(12) : null;
  if (!p) throw new Error('cannot load ' + id);
  return { path: p, base: TW, content: fs.readFileSync(p, 'utf8') };
} });
let css = c.build([...cand]);

// 3. old-phone compatibility: oklch() -> rgb(), opacity colour-mix -> rgb(/alpha), unwrap @layer (CDN output was unlayered)
const lin = v => v <= 0.0031308 ? 12.92 * v : 1.055 * Math.pow(v, 1 / 2.4) - 0.055;
function oklch2rgb(L, C, H) {
  const h = H * Math.PI / 180, a = C * Math.cos(h), b = C * Math.sin(h);
  const l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3, m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3, s = (L - 0.0894841775 * a - 1.2914855480 * b) ** 3;
  const r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s, g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s, bb = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s;
  return [r, g, bb].map(x => Math.max(0, Math.min(255, Math.round(lin(Math.max(0, Math.min(1, x))) * 255))));
}
const vars = {};
css = css.replace(/oklch\(\s*([\d.]+)(%?)\s+([\d.]+)\s+([\d.]+)(?:deg)?\s*(?:\/\s*([\d.]+%?))?\)/g, (_, L, pc, C, H, A) => {
  const [r, g, b] = oklch2rgb(pc ? L / 100 : +L, +C, +H);
  return A ? `rgb(${r} ${g} ${b} / ${A})` : `rgb(${r} ${g} ${b})`;
});
for (const m of css.matchAll(/(--color-[\w-]+):\s*(rgb\([^)]*\)|#[0-9a-fA-F]{3,8})/g)) vars[m[1]] = m[2];
css = css.replace(/color-mix\(in (?:oklab|srgb),\s*(var\((--color-[\w-]+)\)|#[0-9a-fA-F]{3,8}|rgb\([^)]*\))\s+(\d+(?:\.\d+)?)%,\s*transparent\)/g, (all, col, name, pct) => {
  const v = name ? vars[name] : col; if (!v) return all;
  let rgb;
  if (v.startsWith('#')) { const h = v.slice(1), f = h.length === 3 ? h.replace(/./g, x => x + x) : h; rgb = [0, 2, 4].map(i => parseInt(f.slice(i, i + 2), 16)); }
  else rgb = v.match(/[\d.]+/g).slice(0, 3);
  return `rgb(${rgb.join(' ')} / ${pct}%)`;
});
css = css.replace(/@layer\s+[\w\s,.-]+;/g, '');
// unwrap "@layer name { ... }" blocks (brace matching)
for (;;) {
  const i = css.search(/@layer\s+[\w.-]+\s*\{/); if (i < 0) break;
  const o = css.indexOf('{', i); let d = 1, k = o + 1;
  while (d && k < css.length) { if (css[k] === '{') d++; else if (css[k] === '}') d--; k++; }
  css = css.slice(0, i) + css.slice(o + 1, k - 1) + css.slice(k);
}
const out = await esbuild.transform(css, { loader: 'css', minify: true, target: ['chrome80', 'safari13'] });
css = out.code;

// 4. write fast.html
const tag = '<script src="https://cdn.tailwindcss.com"></script>';
if (!html.includes(tag)) throw new Error('tailwind CDN tag not found in index.html');
let h = html.replace(tag, '').replace('<link rel="preconnect" href="https://cdn.tailwindcss.com" crossorigin>\n', '');
h = h.replace('</head>', `<style id="tw-compiled">${css}</style>\n</head>`);
h = h.replace('<title>', '<meta name="robots" content="noindex">\n<title>');
fs.writeFileSync('fast.html', h);
const left = css.match(/oklch|color-mix|@property|@layer/g) || [];
console.log('candidates', cand.size, '| css bytes', css.length, '| html bytes', h.length, '| leftover modern syntax:', [...new Set(left)].join(',') || 'none');
