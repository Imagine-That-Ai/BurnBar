#!/usr/bin/env node
/**
 * test-header-narrow-viewport.mjs — the site header must fit a 320px phone.
 *
 * The failure this guards against actually shipped. `.site-header__inner` is a
 * single non-wrapping flex line, so its width floor is the sum of its children's
 * min-content widths plus the gaps. Flex shrink cannot take an item below that
 * floor, so on a 320px viewport the row stayed 372px wide, painted outside the
 * header, and gave every page a document-level horizontal scrollbar. Page
 * content was innocent — `main` fit fine; the header alone minted the overflow.
 *
 * Nothing in this repo runs a layout engine in CI, so this gate reconstructs the
 * row's width budget from the real declarations instead:
 *
 *   • token values come from tokens.css (`--s-*`, `--gutter`, evaluated at 320px)
 *   • box metrics come from globals.css (`.container`, `.btn`, `.theme-toggle`)
 *     and from the header/brandmark component styles
 *   • the row's membership and every visible label come from the BUILT pages in
 *     dist/, so a new header item or a longer CTA label is measured, not assumed
 *
 * Text advance is bounded, never guessed: see TEXT_ADVANCE_EM below.
 *
 * Four invariants:
 *
 *   1. Contract — the narrow breakpoint exists and does the three things that
 *      make the row fit: tightens the row gap, retires the brand wordmark, and
 *      pins the CTA cluster and the menu button at their intrinsic size so they
 *      can never be squashed again (the menu button used to shrink 36px → 18px).
 *   2. Membership — every built page's header row contains exactly the children
 *      this budget knows how to measure. A new one fails loudly rather than
 *      silently escaping the budget.
 *   3. Budget — the modelled row width at a 320px layout width is ≤ 320px.
 *   4. Affordances — the logo and the menu button keep their full declared size
 *      at 320px. "Fits" must not mean "clipped".
 *
 * Run via: `node scripts/test-header-narrow-viewport.mjs`.
 */

import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const SRC = path.join(ROOT, "src");
const DIST = path.join(ROOT, "dist");

/** The layout width every page must survive. iPhone SE / Galaxy Fold cover. */
const VIEWPORT = 320;
const ROOT_FONT_PX = 16;

/**
 * Upper bound on horizontal advance per character, in em, for the site's faces.
 * Measured against the rendered header in Chromium: the "Download" label is
 * 8 characters of Geist at 0.82rem (13.12px) and occupies 64px — 0.61em each.
 * 0.68em keeps headroom for a heavier weight or a wider fallback face while
 * staying tight enough that a longer label trips the budget instead of sliding
 * under it. Only ever used as a ceiling, so the budget errs toward failing.
 */
const TEXT_ADVANCE_EM = 0.68;

/**
 * Failures are deduplicated by `key`. One header component renders on every
 * page, so a single mistake would otherwise print 44 identical paragraphs and
 * bury the one line that explains it. The first page is named; the rest are
 * counted.
 */
const failures = new Map();
function fail(msg, key = msg) {
  const prior = failures.get(key);
  if (prior) prior.also++;
  else failures.set(key, { msg, also: 0 });
}
const failureLines = () =>
  [...failures.values()].map((f) =>
    f.also ? `${f.msg}\n    (and ${f.also} more built page(s))` : f.msg
  );

// ───────────────────────────── tiny CSS reader ────────────────────────────────
// Deliberately not a CSS parser. It reads declarations out of known rules and
// throws — loudly, by selector name — the moment a rule it depends on moves.

/** Strip block comments, preserving newlines so line math stays usable. */
const decomment = (src) => src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "));

/** Every top-level `@media (max-width: N)` block, as `{ maxWidth, body }`. */
function mediaBlocks(css) {
  const out = [];
  const re = /@media\s*\(\s*max-width:\s*(\d+)px\s*\)\s*\{/g;
  let m;
  while ((m = re.exec(css))) {
    let depth = 1;
    let i = re.lastIndex;
    while (i < css.length && depth > 0) {
      if (css[i] === "{") depth++;
      else if (css[i] === "}") depth--;
      i++;
    }
    out.push({ maxWidth: Number(m[1]), body: css.slice(re.lastIndex, i - 1) });
  }
  return out;
}

/** Declaration blocks of every rule whose selector list contains `selector`, in source order. */
function ruleBodies(css, selector) {
  const esc = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const re = new RegExp(`(?:^|[},])\\s*((?:[^{}]*?,\\s*)?${esc})\\s*\\{([^{}]*)\\}`, "g");
  const out = [];
  let m;
  while ((m = re.exec(css))) out.push(m[2]);
  return out;
}

/** The last block that matches — enough to answer "does this rule exist at all". */
function ruleBody(css, selector) {
  const all = ruleBodies(css, selector);
  return all.length ? all[all.length - 1] : null;
}

/**
 * Value of `prop` on `selector`, taking the last rule that actually declares it
 * (later rules win, and a rule that omits the property does not erase it).
 * Shorthands are not expanded.
 */
function decl(css, selector, prop) {
  const re = new RegExp(`(?:^|;)\\s*${prop}\\s*:\\s*([^;]+)`, "i");
  let found = null;
  for (const body of ruleBodies(css, selector)) {
    const m = body.match(re);
    if (m) found = m[1].trim();
  }
  return found;
}

/** Throwing variant — a missing declaration is a broken gate, not a pass. */
function needDecl(css, where, selector, prop) {
  const v = decl(css, selector, prop);
  if (v == null) throw new Error(`${where}: cannot find \`${prop}\` on \`${selector}\``);
  return v;
}

// ─────────────────────────── length resolution ────────────────────────────────

const tokensSrc = decomment(await readFile(path.join(SRC, "styles", "tokens.css"), "utf8"));
const TOKENS = new Map(
  [...tokensSrc.matchAll(/^\s*(--[a-z0-9-]+)\s*:\s*([^;]+);/gim)].map((m) => [m[1], m[2].trim()])
);

/** Resolve a CSS length to px at VIEWPORT. Handles var(), clamp(), rem/px/vw/em. */
function px(value, { em = ROOT_FONT_PX, seen = new Set() } = {}) {
  let v = String(value).trim();

  const varMatch = v.match(/^var\(\s*(--[a-z0-9-]+)\s*(?:,([^)]*))?\)$/i);
  if (varMatch) {
    const name = varMatch[1];
    if (seen.has(name)) throw new Error(`circular custom property ${name}`);
    const resolved = TOKENS.get(name) ?? varMatch[2];
    if (resolved == null) throw new Error(`unknown custom property ${name}`);
    return px(resolved, { em, seen: new Set([...seen, name]) });
  }

  const clampMatch = v.match(/^clamp\(([^]*)\)$/i);
  if (clampMatch) {
    const parts = splitTopLevel(clampMatch[1]).map((p) => px(p, { em, seen }));
    if (parts.length !== 3) throw new Error(`clamp() needs 3 arguments: ${v}`);
    const [lo, mid, hi] = parts;
    return Math.min(Math.max(mid, lo), hi);
  }

  const num = v.match(/^(-?[\d.]+)(px|rem|em|vw)?$/i);
  if (!num) throw new Error(`cannot resolve length \`${value}\``);
  const n = Number(num[1]);
  switch ((num[2] || "px").toLowerCase()) {
    case "px":
      return n;
    case "rem":
      return n * ROOT_FONT_PX;
    case "em":
      return n * em;
    case "vw":
      return (n * VIEWPORT) / 100;
    default:
      throw new Error(`unsupported unit in \`${value}\``);
  }
}

function splitTopLevel(list) {
  const out = [];
  let depth = 0;
  let cur = "";
  for (const ch of list) {
    if (ch === "(") depth++;
    if (ch === ")") depth--;
    if (ch === "," && depth === 0) {
      out.push(cur);
      cur = "";
    } else cur += ch;
  }
  if (cur.trim()) out.push(cur);
  return out.map((s) => s.trim());
}

/** Horizontal padding sum of a `padding: …` shorthand (1–4 values). */
function paddingX(shorthand, em) {
  const parts = shorthand.trim().split(/\s+/);
  const left = parts.length >= 4 ? parts[3] : parts.length >= 2 ? parts[1] : parts[0];
  const right = parts.length >= 2 ? parts[1] : parts[0];
  return px(left, { em }) + px(right, { em });
}

/** Border width from a `border: 1px solid …` shorthand, both sides. */
function borderX(shorthand) {
  const m = String(shorthand).match(/(-?[\d.]+(?:px|rem|em))/);
  return m ? px(m[1]) * 2 : 0;
}

/** Conservative rendered width of a label. Whitespace is collapsed first. */
const textWidth = (label, fontPx) =>
  label.replace(/\s+/g, " ").trim().length * fontPx * TEXT_ADVANCE_EM;

// ────────────────────────────── source styles ─────────────────────────────────

const globals = decomment(await readFile(path.join(SRC, "styles", "globals.css"), "utf8"));
const headerSrc = await readFile(path.join(SRC, "components", "Header.astro"), "utf8");
const brandSrc = await readFile(path.join(SRC, "components", "Brandmark.astro"), "utf8");
const styleOf = (astro) =>
  decomment([...astro.matchAll(/<style>([\s\S]*?)<\/style>/g)].map((m) => m[1]).join("\n"));
const headerCss = styleOf(headerSrc);
const brandCss = styleOf(brandSrc);

const headerMedia = mediaBlocks(headerCss);
const globalsMedia = mediaBlocks(globals);

/** True when `selector` is set to `display: none` in a block that covers 320px. */
const hiddenAtViewport = (blocks, selector) =>
  blocks.some(
    (b) =>
      b.maxWidth >= VIEWPORT && (decl(b.body, selector, "display") ?? "").toLowerCase() === "none"
  );

/** The narrowest `@media (max-width:…)` block covering 320px that touches `selector`. */
const narrowBlockFor = (blocks, selector) =>
  blocks
    .filter((b) => b.maxWidth >= VIEWPORT && ruleBody(b.body, selector) != null)
    .sort((a, b) => a.maxWidth - b.maxWidth)[0] ?? null;

// ───────────────── invariant 1: the narrow-viewport contract ──────────────────

const gapBlock = narrowBlockFor(headerMedia, ".site-header__inner");
if (!gapBlock) {
  fail(
    "Header.astro: no `@media (max-width: …)` rule sets `.site-header__inner` for narrow phones. " +
      "The row needs a tighter gap below the mobile breakpoint or it cannot reach 320px."
  );
}

const wordmarkHidden = hiddenAtViewport(headerMedia, ".site-header__inner :global(.wordmark)");
if (!wordmarkHidden) {
  fail(
    "Header.astro: the brand wordmark is no longer hidden at narrow widths. " +
      "It is the one item with slack in the row — without it the line floor exceeds 320px."
  );
}

for (const selector of [".site-header__cta", ".site-header__menu"]) {
  const flex = decl(headerCss, selector, "flex");
  if (flex !== "none") {
    fail(
      `Header.astro: \`${selector}\` must declare \`flex: none\` (found ${flex ?? "nothing"}). ` +
        "Without it flex shrink squashes it — the menu button used to render 18px wide instead of 36px."
    );
  }
}

if (!hiddenAtViewport(headerMedia, ".site-nav")) {
  fail(
    "Header.astro: `.site-nav` is no longer hidden on small screens; the 320px budget assumes it is."
  );
}
if (!hiddenAtViewport(headerMedia, ".site-header__cta .btn--ghost")) {
  fail(
    "Header.astro: the ghost CTA is no longer hidden on small screens; the 320px budget assumes it is."
  );
}

// ───────────────────────── measured box metrics ───────────────────────────────

const gutter = px(needDecl(globals, "globals.css", ".container", "padding-inline"));
const baseRowGap = px(needDecl(headerCss, "Header.astro", ".site-header__inner", "gap"));
// No narrow block is itself a failure (invariant 1); fall back to the base gap
// so the budget below still reports a real number rather than Infinity.
const rowGap = gapBlock
  ? px(needDecl(gapBlock.body, "Header.astro narrow block", ".site-header__inner", "gap"))
  : baseRowGap;
const ctaGap = px(needDecl(headerCss, "Header.astro", ".site-header__cta", "gap"));
const brandGap = px(needDecl(brandCss, "Brandmark.astro", ".brand", "gap"));
const brandFontPx = px(needDecl(brandCss, "Brandmark.astro", ".brand", "font-size"));
const themeToggleW = px(needDecl(globals, "globals.css", ".theme-toggle", "width"));
const menuW = px(needDecl(headerCss, "Header.astro", ".site-header__menu", "width"));
const arrowW = px(needDecl(globals, "globals.css", ".btn .btn-arrow", "width"));

const btnFontPx = px(needDecl(globals, "globals.css", ".btn--small", "font-size"));
const btnPadX = paddingX(needDecl(globals, "globals.css", ".btn--small", "padding"), btnFontPx);
const btnBorderX = borderX(needDecl(globals, "globals.css", ".btn", "border"));
const btnGap = px(needDecl(globals, "globals.css", ".btn", "gap"), { em: btnFontPx });

/** Width of a `.btn--small` carrying `label`, plus the arrow when present. */
const smallButtonWidth = (label, hasArrow) =>
  btnPadX + btnBorderX + textWidth(label, btnFontPx) + (hasArrow ? btnGap + arrowW : 0);

// ───────────── invariants 2–4: membership, budget, affordances ────────────────

/** Direct element children of the header row, in document order. */
function rowChildren(html) {
  const start = html.indexOf('class="site-header__inner');
  if (start < 0) return null;
  const open = html.lastIndexOf("<", start);
  let i = html.indexOf(">", start) + 1;
  let depth = 1;
  const children = [];
  const tagRe = /<(\/?)([a-z0-9-]+)([^>]*)>/gi;
  tagRe.lastIndex = i;
  let m;
  let childStart = null;
  // True HTML voids only. SVG children (path, circle, …) are serialised with
  // explicit closing tags in Astro's output, so treating them as void here would
  // desynchronise the depth counter and truncate the child list.
  const VOID = new Set([
    "img",
    "br",
    "hr",
    "input",
    "meta",
    "link",
    "source",
    "col",
    "area",
    "embed",
    "track",
    "wbr"
  ]);
  while ((m = tagRe.exec(html))) {
    const closing = m[1] === "/";
    const tag = m[2].toLowerCase();
    const selfClosing = VOID.has(tag) || m[3].trim().endsWith("/");
    if (!closing) {
      if (depth === 1 && !selfClosing) childStart = m.index;
      if (depth === 1 && selfClosing) children.push(html.slice(m.index, tagRe.lastIndex));
      if (!selfClosing) depth++;
    } else {
      depth--;
      if (depth === 0) break;
      if (depth === 1 && childStart != null) {
        children.push(html.slice(childStart, tagRe.lastIndex));
        childStart = null;
      }
    }
  }
  void open;
  return children;
}

const classesOf = (frag) => {
  const m = frag.match(/^<[a-z0-9-]+[^>]*\sclass="([^"]*)"/i);
  return new Set((m ? m[1] : "").split(/\s+/).filter(Boolean));
};
/**
 * Visible label of a fragment. Icons are removed first: `<svg>` art and the
 * `.btn-arrow` glyph are sized from their own CSS `width`, so leaving them in
 * the string would charge for them twice.
 */
const textOf = (frag) =>
  frag
    .replace(/<svg[\s\S]*?<\/svg>/gi, " ")
    .replace(/<span[^>]*class="[^"]*btn-arrow[^"]*"[^>]*>[\s\S]*?<\/span>/gi, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();

async function builtPages(dir) {
  const out = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...(await builtPages(full)));
    else if (entry.name.endsWith(".html")) out.push(full);
  }
  return out;
}

let pages;
try {
  pages = await builtPages(DIST);
} catch {
  throw new Error("dist/ does not exist — run `npm run build` before this gate.");
}
if (pages.length < 20) throw new Error(`expected the full built site, found ${pages.length} pages`);

let checked = 0;
let widest = { page: null, width: 0 };

for (const file of pages) {
  const html = await readFile(file, "utf8");
  const children = rowChildren(html);
  if (children == null) continue; // 404 shell and other header-less pages
  const rel = path.relative(ROOT, file);
  checked++;

  let content = 0;
  let items = 0;
  let sawLogo = false;
  let sawMenu = false;

  for (const child of children) {
    const cls = classesOf(child);

    if (cls.has("brand")) {
      const logo = child.match(/<img[^>]*class="[^"]*brand__logo[^"]*"[^>]*>/i);
      if (!logo) {
        fail(
          `${rel}: the brand no longer renders a logo image; the 320px budget cannot size it.`,
          "brand-logo-missing"
        );
        continue;
      }
      const w = logo[0].match(/\swidth="(\d+)"/i);
      if (!w) {
        fail(`${rel}: the brand logo has no intrinsic \`width\` attribute.`, "brand-logo-width");
        continue;
      }
      sawLogo = Number(w[1]) > 0;
      content += Number(w[1]);
      // The wordmark is retired at this width (invariant 1). If that rule ever
      // goes away, charge the budget for the text so the number stays honest.
      if (!wordmarkHidden) {
        const wm = child.match(
          /<span[^>]*class="[^"]*\bwordmark\b[^"]*"[^>]*>[\s\S]*?<\/span>\s*<\/a>/i
        );
        if (wm) content += brandGap + textWidth(textOf(wm[0]), brandFontPx);
      }
      items++;
    } else if (cls.has("site-nav")) {
      continue; // display:none below the mobile breakpoint (asserted above)
    } else if (cls.has("site-header__cta")) {
      let cta = 0;
      let ctaItems = 0;
      const inner = child.replace(/^<div[^>]*>/i, "").replace(/<\/div>\s*$/i, "");
      const parts = inner.match(/<(button|a)\b[\s\S]*?<\/\1>/gi) ?? [];
      for (const part of parts) {
        const pc = classesOf(part);
        if (pc.has("btn--ghost")) continue; // display:none below the mobile breakpoint
        if (pc.has("theme-toggle")) {
          cta += themeToggleW;
          ctaItems++;
        } else if (pc.has("btn")) {
          if (!pc.has("btn--small")) {
            fail(
              `${rel}: header CTA button "${textOf(part)}" is not \`.btn--small\`; the budget sizes small buttons only.`,
              `cta-not-small:${textOf(part)}`
            );
            continue;
          }
          const hasArrow = /class="[^"]*btn-arrow/.test(part);
          cta += smallButtonWidth(textOf(part), hasArrow);
          ctaItems++;
        } else {
          fail(
            `${rel}: unmodelled header CTA item "${textOf(part)}".`,
            `cta-unmodelled:${textOf(part)}`
          );
        }
      }
      if (ctaItems > 0) {
        content += cta + ctaGap * (ctaItems - 1);
        items++;
      }
    } else if (cls.has("site-header__menu")) {
      sawMenu = true;
      content += menuW;
      items++;
    } else if (cls.has("skip-link")) {
      continue; // absolutely positioned off-canvas until focused
    } else {
      fail(
        `${rel}: the header row gained an item this 320px budget cannot measure ` +
          `(classes: ${[...cls].join(" ") || "none"}). Model it here, or keep it out of the narrow row.`,
        `row-unmodelled:${[...cls].join(" ")}`
      );
    }
  }

  // Invariant 4 — the two affordances that must survive at full size.
  if (!sawLogo) fail(`${rel}: the header row lost its logo.`, "row-no-logo");
  if (!sawMenu) fail(`${rel}: the header row lost its mobile menu button.`, "row-no-menu");
  if (menuW < 36)
    fail(`Header.astro: the menu button is ${menuW}px; keep it at least 36px for touch.`);

  // Invariant 3 — the budget.
  const total = gutter * 2 + content + rowGap * Math.max(0, items - 1);
  if (total > widest.width) widest = { page: rel, width: total };
  if (total > VIEWPORT) {
    fail(
      `${rel}: header row needs ${total.toFixed(1)}px at a ${VIEWPORT}px layout width ` +
        `(gutters ${(gutter * 2).toFixed(0)} + items ${content.toFixed(1)} + ${Math.max(0, items - 1)} gap(s) ` +
        `${(rowGap * Math.max(0, items - 1)).toFixed(0)}). It will overflow the document and mint a scrollbar.`,
      `budget:${total.toFixed(1)}`
    );
  }
}

if (checked === 0) throw new Error("no built page carried a `.site-header__inner` row to measure");

if (failures.size) {
  console.error(`\n✗ header narrow-viewport gate — ${failures.size} failure(s):\n`);
  for (const line of failureLines()) console.error(`  • ${line}\n`);
  process.exit(1);
}

console.log(
  `✓ header fits ${VIEWPORT}px on all ${checked} built pages ` +
    `(worst: ${widest.width.toFixed(1)}px on ${widest.page}, ${(VIEWPORT - widest.width).toFixed(1)}px of slack)`
);
