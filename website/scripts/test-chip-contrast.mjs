#!/usr/bin/env node
/**
 * test-chip-contrast.mjs — the `.tag` chip is the smallest text on this site
 * (12.8px mono) and the most reused, and until this test existed its colour
 * contrast was an accident of layout rather than a property of the palette.
 *
 * How it used to fail: `.tag` painted a TRANSLUCENT ground (--ink-surface)
 * over whatever was behind it, so the same foreground measured
 *
 *     #0c7c69 on the bare page ground .............. 4.65:1   (AA)
 *     #0c7c69 on a card ............................ 4.29:1   (fail)
 *     #0c7c69 two cards deep ....................... 4.00:1   (fail)
 *
 * A reviewer could measure the chip on one page, call it AA, and be wrong
 * three routes over. Nobody could check it statically either, because the
 * answer depended on the DOM.
 *
 * The fix that makes this file possible: the chip ground is now PINNED to an
 * opaque token per theme (--chip-ground / --chip-ground-ember). Contrast is
 * therefore a property of one (foreground token, ground token) pair, and the
 * whole guarantee is checkable here, offline, in milliseconds — no browser,
 * no dev server, no headless Chromium in CI.
 *
 * Four invariants:
 *
 *   1. Every chip ground token is OPAQUE. The moment one goes translucent the
 *      ground stops being knowable and invariant 3 is measuring a fiction, so
 *      this fails loudly rather than silently degrading.
 *
 *   2. Every chip ground token still equals the surface it replaced —
 *      --chip-ground       == --ink-surface over --ink-void
 *      --chip-ground-ember == --ember-wash  over --ink-void
 *      This is what stops "fix the contrast" from turning into "repaint the
 *      chip": the pinned value has to stay the flattened form of the glass it
 *      stands in for, in both themes.
 *
 *   3. Every chip variant clears WCAG 2.1 AA (4.5:1, small text) against its
 *      own ground, in BOTH themes. Variants and their colours are read out of
 *      the stylesheets, so a new `.tag--whatever` is covered the day it lands.
 *
 *   4. No stylesheet outside globals.css restyles a `.tag` background. A
 *      per-page override would reintroduce exactly the placement-dependent
 *      ground this whole design removes.
 *
 * Run via: `node scripts/test-chip-contrast.mjs`.
 */

import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const STYLES = path.join(ROOT, "src", "styles");
const TOKENS = path.join(STYLES, "tokens.css");
const GLOBALS = path.join(STYLES, "globals.css");

/** WCAG 2.1 AA for text below 18.66px bold / 24px regular. Chips are 12.8px. */
const AA_SMALL = 4.5;

/* ------------------------------------------------------------------ colour */

const clamp255 = (n) => Math.max(0, Math.min(255, n));

/** Parse the CSS colour syntaxes this palette actually uses. */
function parseColor(input) {
  const value = String(input).trim();

  const hex = value.match(/^#([0-9a-f]{3,8})$/i);
  if (hex) {
    let h = hex[1];
    if (h.length === 3 || h.length === 4) h = [...h].map((c) => c + c).join("");
    if (h.length !== 6 && h.length !== 8) return null;
    return {
      r: parseInt(h.slice(0, 2), 16),
      g: parseInt(h.slice(2, 4), 16),
      b: parseInt(h.slice(4, 6), 16),
      a: h.length === 8 ? parseInt(h.slice(6, 8), 16) / 255 : 1
    };
  }

  const fn = value.match(/^rgba?\(([^)]+)\)$/i);
  if (fn) {
    const parts = fn[1].split(/[,\s/]+/).filter(Boolean);
    if (parts.length < 3) return null;
    const n = parts.map((p) => (p.endsWith("%") ? (parseFloat(p) / 100) * 255 : parseFloat(p)));
    if (n.slice(0, 3).some(Number.isNaN)) return null;
    let a = 1;
    if (parts.length > 3) {
      a = parts[3].endsWith("%") ? parseFloat(parts[3]) / 100 : parseFloat(parts[3]);
      if (Number.isNaN(a)) return null;
    }
    return { r: clamp255(n[0]), g: clamp255(n[1]), b: clamp255(n[2]), a };
  }

  return null;
}

/** Source-over composite of a (possibly translucent) colour onto an opaque one. */
const over = (fg, bg) => ({
  r: fg.r * fg.a + bg.r * (1 - fg.a),
  g: fg.g * fg.a + bg.g * (1 - fg.a),
  b: fg.b * fg.a + bg.b * (1 - fg.a),
  a: 1
});

const hex = (c) =>
  "#" + [c.r, c.g, c.b].map((v) => Math.round(clamp255(v)).toString(16).padStart(2, "0")).join("");

/** WCAG relative luminance (sRGB). */
function luminance(c) {
  const ch = (v) => {
    const s = v / 255;
    return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
  };
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

function contrast(a, b) {
  const [x, y] = [luminance(a), luminance(b)];
  return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
}

/** Same colour, within one 8-bit step per channel. Rounding, not repainting. */
const sameColor = (a, b) =>
  Math.abs(a.r - b.r) <= 1 && Math.abs(a.g - b.g) <= 1 && Math.abs(a.b - b.b) <= 1;

/* ------------------------------------------------------------------ tokens */

/** Strip comments, then walk braces to yield every top-level `selector { body }`. */
function* topLevelRules(css) {
  const src = css.replace(/\/\*[\s\S]*?\*\//g, "");
  let depth = 0;
  let start = 0;
  let head = "";
  for (let i = 0; i < src.length; i++) {
    const ch = src[i];
    if (ch === "{") {
      if (depth === 0) {
        head = src.slice(start, i).trim();
        start = i + 1;
      }
      depth++;
    } else if (ch === "}") {
      depth--;
      if (depth === 0) {
        yield { selector: head, body: src.slice(start, i) };
        start = i + 1;
      }
      if (depth < 0) depth = 0;
    }
  }
}

/** Body of the first top-level rule whose selector list matches `selector`. */
function ruleBody(css, selector) {
  for (const rule of topLevelRules(css)) {
    if (rule.selector.split(",").some((s) => s.trim() === selector)) return rule.body;
  }
  return null;
}

function declaredCustomProps(body) {
  const out = new Map();
  for (const m of body.matchAll(/(--[\w-]+)\s*:\s*([^;]+);/g)) {
    out.set(
      m[1],
      m[2]
        .trim()
        .replace(/\s*\/\*.*?\*\/\s*/gs, "")
        .trim()
    );
  }
  return out;
}

/**
 * Resolve a token value through `var()` chains. `light` shadows `dark`, which
 * mirrors the cascade: :root[data-theme="light"] only overrides what it names.
 */
function makeResolver(base, overlay) {
  const lookup = (name) => (overlay?.has(name) ? overlay.get(name) : base.get(name));
  return function resolve(value, seen = new Set()) {
    let v = String(value).trim();
    for (let i = 0; i < 12; i++) {
      const m = v.match(/^var\(\s*(--[\w-]+)\s*(?:,\s*([^)]*))?\)$/);
      if (!m) return v;
      if (seen.has(m[1])) return v;
      seen.add(m[1]);
      const next = lookup(m[1]);
      if (next === undefined) {
        if (m[2] === undefined) return null;
        v = m[2].trim();
        continue;
      }
      v = next;
    }
    return v;
  };
}

/* ------------------------------------------------- chip variants from CSS */

/**
 * Read the `.tag` family out of a stylesheet: the base rule supplies the
 * default colour and ground, each `.tag--x` rule overrides one or both.
 * Selectors are matched as whole rules so `.tag::before` and descendant
 * selectors never masquerade as variants.
 */
function collectVariants(css, sourceLabel, into) {
  for (const rule of topLevelRules(css)) {
    for (const raw of rule.selector.split(",")) {
      const selector = raw.trim();
      if (!/^\.tag(--[\w-]+)?$/.test(selector)) continue;
      const name = selector.slice(1);
      const entry = into.get(name) ?? { name, color: null, background: null, from: sourceLabel };
      const color = rule.body.match(/(?:^|[;{\s])color\s*:\s*([^;]+)/);
      const bg = rule.body.match(/(?:^|[;{\s])background(?:-color)?\s*:\s*([^;]+)/);
      if (color) entry.color = color[1].trim();
      if (bg) entry.background = bg[1].trim();
      into.set(name, entry);
    }
  }
  return into;
}

/* -------------------------------------------------------------------- run */

const failures = [];
const note = (msg) => failures.push(msg);

const tokensSrc = await readFile(TOKENS, "utf8");
const globalsSrc = await readFile(GLOBALS, "utf8");

const darkBody = ruleBody(tokensSrc, ":root");
const lightBody = ruleBody(tokensSrc, ':root[data-theme="light"]');
if (!darkBody || !lightBody) {
  console.error("chip-contrast: could not find the :root / :root[data-theme=light] token blocks");
  process.exit(1);
}
const darkTokens = declaredCustomProps(darkBody);
const lightTokens = declaredCustomProps(lightBody);

const THEMES = [
  { id: "dark", resolve: makeResolver(darkTokens) },
  { id: "light", resolve: makeResolver(darkTokens, lightTokens) }
];

/** Every stylesheet, so a chip rule hiding in bench.css is still covered. */
const styleFiles = (await readdir(STYLES)).filter((f) => f.endsWith(".css")).sort();
const variants = new Map();
for (const file of styleFiles) {
  const src = file === "globals.css" ? globalsSrc : await readFile(path.join(STYLES, file), "utf8");
  collectVariants(src, file, variants);
}

// ---- invariant 4: only globals.css may set a chip background.
for (const v of variants.values()) {
  if (v.background && v.from !== "globals.css") {
    note(
      `${v.from}\n    .${v.name} sets a chip background. Chip grounds live in globals.css so ` +
        `they stay pinned and checkable — override the token, not the rule.`
    );
  }
}

const base = variants.get("tag");
if (!base?.color || !base?.background) {
  console.error("chip-contrast: the base `.tag` rule must declare both color and background");
  process.exit(1);
}

const GROUND_DERIVATIONS = [
  { ground: "--chip-ground", wash: "--ink-surface", under: "--ink-void" },
  { ground: "--chip-ground-ember", wash: "--ember-wash", under: "--ink-void" }
];

const rows = [];

for (const theme of THEMES) {
  // ---- invariants 1 + 2: the pinned grounds are opaque and still honest.
  for (const d of GROUND_DERIVATIONS) {
    const pinned = parseColor(theme.resolve(`var(${d.ground})`) ?? "");
    if (!pinned) {
      note(`tokens.css\n    ${theme.id}: ${d.ground} is missing or not a parseable colour`);
      continue;
    }
    if (pinned.a !== 1) {
      note(
        `tokens.css\n    ${theme.id}: ${d.ground} is translucent (alpha ${pinned.a}). A chip ` +
          `ground must be opaque or its contrast depends on the card behind it again.`
      );
      continue;
    }
    const wash = parseColor(theme.resolve(`var(${d.wash})`) ?? "");
    const under = parseColor(theme.resolve(`var(${d.under})`) ?? "");
    if (!wash || !under) continue;
    const expected = over(wash, under);
    if (!sameColor(pinned, expected)) {
      note(
        `tokens.css\n    ${theme.id}: ${d.ground} is ${hex(pinned)} but ${d.wash} over ` +
          `${d.under} flattens to ${hex(expected)}. Pinning the ground may not restyle the ` +
          `chip — set ${d.ground} to ${hex(expected)}, or change the wash it derives from.`
      );
    }
  }

  // ---- invariant 3: every variant clears AA on its own ground.
  for (const v of [...variants.values()].sort((a, b) => a.name.localeCompare(b.name))) {
    const rawFg = v.color ?? base.color;
    const rawBg = v.background ?? base.background;
    const fgVal = theme.resolve(rawFg);
    const bgVal = theme.resolve(rawBg);
    const bgColor = parseColor(bgVal ?? "");
    const fgColor = parseColor(fgVal ?? "");
    if (!bgColor || !fgColor) {
      note(
        `${v.from}\n    ${theme.id}: .${v.name} — could not resolve ` +
          `${!fgColor ? `color ${rawFg}` : `background ${rawBg}`} to a colour`
      );
      continue;
    }
    const ground = bgColor.a === 1 ? bgColor : over(bgColor, { r: 255, g: 255, b: 255, a: 1 });
    const text = fgColor.a === 1 ? fgColor : over(fgColor, ground);
    const ratio = contrast(text, ground);
    rows.push({ theme: theme.id, name: v.name, fg: hex(text), bg: hex(ground), ratio });
    if (ratio < AA_SMALL) {
      note(
        `${v.from}\n    ${theme.id}: .${v.name} — ${hex(text)} on ${hex(ground)} is ` +
          `${ratio.toFixed(2)}:1, below WCAG AA ${AA_SMALL}:1 for small text. ` +
          `Darken (light theme) or lighten (dark theme) the foreground token; keep the hue.`
      );
    }
  }
}

if (failures.length) {
  console.error(`\nchip-contrast: ${failures.length} violation(s)\n`);
  for (const f of failures) console.error("  " + f + "\n");
  console.error("See src/styles/tokens.css § chip ground for the design this test guards.\n");
  process.exit(1);
}

const worst = rows.reduce((a, b) => (a.ratio <= b.ratio ? a : b));
for (const r of rows.sort((a, b) => a.theme.localeCompare(b.theme) || a.ratio - b.ratio)) {
  console.log(
    `  ${r.theme.padEnd(5)} .${r.name.padEnd(18)} ${r.fg} on ${r.bg}  ${r.ratio.toFixed(2)}:1`
  );
}
console.log(
  `chip-contrast: ${variants.size} chip variant(s) × ${THEMES.length} themes · ` +
    `grounds opaque and derivation-exact · worst ${worst.ratio.toFixed(2)}:1 ` +
    `(${worst.theme} .${worst.name}) vs AA ${AA_SMALL}:1`
);
