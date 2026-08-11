#!/usr/bin/env node
/**
 * test-typography.mjs — the typography token system is load-bearing, and it
 * rots silently. This test is what keeps it honest.
 *
 * The system (see src/styles/tokens.css § TYPOGRAPHY):
 *   families  --font-display / --font-body / --font-mono
 *   weight    --wght-*  applied with `font-weight`
 *   optical   --opsz-*  applied by assigning `--opsz`
 *
 * Four invariants, each guarding a failure this site actually shipped:
 *
 *   1. No raw font stacks. Every font-family resolves to a token, so
 *      changing a face is one edit and never leaves a page behind.
 *
 *   2. No "wght" inside font-variation-settings. This is the big one.
 *      font-variation-settings is a LOW-LEVEL property: a registered axis
 *      set there overrides the matching high-level property (font-weight)
 *      AND inherits. globals.css used to carry `"wght" 400` on <body>, which
 *      inherited into everything and silently voided all 66 font-weight
 *      declarations on the site — h2 asked for 800 and rendered 400, while
 *      components that happened to set their own "wght" rendered anywhere
 *      from 340 to 800. Same-level headings looked like different typefaces.
 *      Weight travels by font-weight only.
 *
 *   3. font-variation-settings is declared in exactly one place — the
 *      engine rule in globals.css. Everything else assigns `--opsz`.
 *
 *   4. No off-scale literals. font-weight and --opsz take a token, never a
 *      number, so the scale can't quietly regrow the 20 weights and 7
 *      optical sizes it started with.
 *
 * Run via: `node scripts/test-typography.mjs`.
 */

import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const SRC = path.join(ROOT, "src");
const TOKENS = path.join(SRC, "styles", "tokens.css");
const GLOBALS = path.join(SRC, "styles", "globals.css");

const failures = [];
const fail = (file, line, msg, snippet) =>
  failures.push(`${path.relative(ROOT, file)}:${line}\n    ${msg}\n    → ${snippet.trim()}`);

async function walk(dir) {
  const out = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...(await walk(full)));
    else if (/\.(astro|css)$/.test(entry.name)) out.push(full);
  }
  return out;
}

/** Strip CSS block comments and Astro/JSX `{/* … *\/}` so prose never trips a rule. */
const decomment = (src) => src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "));

const files = await walk(SRC);
if (files.length < 50)
  throw new Error(`expected to scan the site, found only ${files.length} files`);

// ───────────── invariant 0: the token scales exist and are the source ─────────
const tokensSrc = await readFile(TOKENS, "utf8");
const WGHT = [...tokensSrc.matchAll(/^\s*(--wght-[a-z]+):/gm)].map((m) => m[1]);
const OPSZ = [...tokensSrc.matchAll(/^\s*(--opsz-[a-z0-9]+):/gm)].map((m) => m[1]);
if (WGHT.length < 5) throw new Error("tokens.css lost its --wght-* scale");
if (OPSZ.length < 5) throw new Error("tokens.css lost its --opsz-* scale");
for (const family of ["--font-display", "--font-body", "--font-mono"]) {
  if (!tokensSrc.includes(`${family}:`)) throw new Error(`tokens.css lost ${family}`);
}
// --font-display must degrade to a serif, never to the body sans: Fraunces swaps
// in after first paint, and a serif→sans fallback restyles every heading mid-load.
// (`sans-serif` ends in "serif" — the lookbehind is what makes this test real.)
const displayDecl = tokensSrc.match(/--font-display:([^;]+);/s)?.[1] ?? "";
if (!/(?<!sans-)serif\s*$/.test(displayDecl.trim())) {
  failures.push(
    `${path.relative(ROOT, TOKENS)}\n    --font-display must end in a serif fallback ` +
      `(a sans fallback restyles headings during the font swap)\n    → ${displayDecl.trim()}`
  );
}

for (const file of files) {
  const raw = await readFile(file, "utf8");
  const src = decomment(raw);
  const lines = src.split("\n");
  const isEngine = file === GLOBALS;

  lines.forEach((text, i) => {
    const n = i + 1;

    // 1. font-family must resolve to a token (CSS property or SVG attribute).
    //    Defining a --font-* token itself is how a section re-points its
    //    display face (bench does this on .ins), so those lines are the
    //    declaration, not a violation.
    if (!/^\s*--font-[a-z-]+\s*:/.test(text)) {
      for (const m of text.matchAll(/font-family\s*[:=]\s*"?([^;"'}]+)/g)) {
        const value = m[1].trim();
        if (!value.startsWith("var(--font-"))
          fail(file, n, "raw font stack — use a --font-* token", text);
      }
    }

    // 2/4. font-weight must be a token (SVG presentation attrs included).
    for (const m of text.matchAll(/font-weight\s*[:=]\s*"?([^;"'}>]+)/g)) {
      const value = m[1].trim();
      if (value.startsWith("var(--wght-") || value === "inherit") continue;
      fail(file, n, "off-scale font-weight — use a --wght-* token", text);
    }

    // 4. --opsz must be assigned a token.
    for (const m of text.matchAll(/(?<!-)--opsz\s*:\s*([^;}]+)/g)) {
      const value = m[1].trim();
      if (!value.startsWith("var(--opsz-"))
        fail(file, n, "off-scale --opsz — use an --opsz-* token", text);
    }
  });

  // 2/3. font-variation-settings: only the engine may declare it, and no
  // declaration anywhere may name "wght".
  for (const m of src.matchAll(/font-variation-settings\s*:\s*([^;}]+)/g)) {
    const n = src.slice(0, m.index).split("\n").length;
    const value = m[1];
    if (/"wght"/.test(value)) {
      fail(
        file,
        n,
        '"wght" in font-variation-settings overrides and inherits — use font-weight',
        value
      );
    }
    if (!isEngine) {
      fail(
        file,
        n,
        "font-variation-settings belongs to the engine rule in globals.css — assign --opsz",
        value
      );
    } else if (!/var\(--opsz/.test(value)) {
      fail(file, n, "the engine rule must feed --opsz into the font", value);
    }
  }
}

// ───────────── invariant 3: the engine rule is actually present ──────────────
const globalsSrc = decomment(await readFile(GLOBALS, "utf8"));
const engine = [...globalsSrc.matchAll(/font-variation-settings\s*:\s*([^;}]+)/g)];
if (engine.length !== 1) {
  failures.push(
    `${path.relative(ROOT, GLOBALS)}\n    expected exactly 1 font-variation-settings ` +
      `declaration (the optical-size engine), found ${engine.length}`
  );
}
if (!/:where\(\*\)\s*\{[^}]*font-variation-settings/s.test(globalsSrc)) {
  failures.push(
    `${path.relative(ROOT, GLOBALS)}\n    the optical-size engine must stay on :where(*) so ` +
      `setting --opsz alone is sufficient and components can still override it`
  );
}

if (failures.length) {
  console.error(`\ntypography: ${failures.length} violation(s)\n`);
  for (const f of failures) console.error("  " + f + "\n");
  console.error("See src/styles/tokens.css § TYPOGRAPHY for the three rules.\n");
  process.exit(1);
}

console.log(
  `typography: ${files.length} files · ${WGHT.length} weight tokens · ${OPSZ.length} optical-size tokens · ` +
    `1 font-variation-settings declaration site-wide · no raw stacks, no inherited "wght"`
);
