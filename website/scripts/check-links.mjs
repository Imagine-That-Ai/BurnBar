#!/usr/bin/env node
/* Walk dist/, parse every HTML file, and check:
 *   - all internal hrefs resolve to a built page or static asset
 *   - external https:// hrefs are well-formed
 * Reports a non-zero exit code on broken links.
 *
 * No network requests (so it's CI-friendly). External link liveness
 * is delegated to a separate periodic check.
 */

import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { join, relative } from "node:path";

const DIST = new URL("../dist", import.meta.url).pathname;
const RED = "\x1b[31m";
const GREEN = "\x1b[32m";
const YELLOW = "\x1b[33m";
const DIM = "\x1b[2m";
const RESET = "\x1b[0m";

function walk(dir) {
  const out = [];
  for (const e of readdirSync(dir)) {
    const p = join(dir, e);
    if (statSync(p).isDirectory()) out.push(...walk(p));
    else if (e.endsWith(".html")) out.push(p);
  }
  return out;
}

function builtRoutes(dir) {
  const set = new Set();
  for (const e of readdirSync(dir)) {
    const p = join(dir, e);
    if (statSync(p).isDirectory()) {
      for (const r of builtRoutes(p)) set.add(r);
    } else if (e === "index.html") {
      const rel = "/" + relative(DIST, dir).replace(/\\/g, "/");
      set.add(rel === "/." ? "/" : rel);
    } else if (e.endsWith(".html")) {
      const rel = "/" + relative(DIST, p).replace(/\\/g, "/").replace(/\.html$/, "");
      set.add(rel);
    }
  }
  return set;
}

function hasAsset(href) {
  // /favicon.svg, /og/default.svg, /robots.txt, /sitemap.xml, /_assets/*
  return existsSync(join(DIST, href.replace(/^\//, "")));
}

function* hrefs(html) {
  const re = /href\s*=\s*"([^"]+)"/gi;
  let m;
  while ((m = re.exec(html)) !== null) yield m[1];
}

if (!existsSync(DIST)) {
  console.error(`${RED}dist/ does not exist — run "astro build" first.${RESET}`);
  process.exit(1);
}

const routes = builtRoutes(DIST);
const files = walk(DIST);
let totalLinks = 0;
let broken = 0;
const issues = [];

for (const f of files) {
  const html = readFileSync(f, "utf-8");
  const fileRel = relative(DIST, f);
  for (const h of hrefs(html)) {
    totalLinks++;
    // Strip any leading whitespace / quotes before scheme check so URLs like
    // " javascript:..." or "JaVaScRiPt:..." cannot bypass the prefix match
    // (CodeQL: js/incomplete-url-scheme-check).
    const trimmed = h.trim().toLowerCase();
    if (
      trimmed.startsWith("#") ||
      trimmed.startsWith("mailto:") ||
      trimmed.startsWith("tel:") ||
      trimmed.startsWith("data:") ||
      trimmed.startsWith("javascript:") ||
      trimmed.startsWith("vbscript:")
    ) continue;

    if (h.startsWith("http://") || h.startsWith("https://")) {
      // Validate format only (no network).
      try {
        new URL(h);
      } catch {
        broken++;
        issues.push(`${fileRel}: malformed URL ${h}`);
      }
      continue;
    }

    // Internal href — strip query/fragment, normalize trailing slash
    const cleaned = h.replace(/[?#].*$/, "").replace(/\/$/, "") || "/";
    if (routes.has(cleaned)) continue;
    if (cleaned !== "/" && routes.has(cleaned + "/")) continue;
    if (hasAsset(cleaned)) continue;

    // Allow "" empty
    if (h === "") continue;

    broken++;
    issues.push(`${fileRel}: unresolved ${h}`);
  }
}

console.log(`${DIM}Scanned ${files.length} HTML files, ${totalLinks} hrefs.${RESET}`);
console.log(`${DIM}Known routes: ${routes.size}${RESET}`);
if (broken > 0) {
  console.log(`${RED}✗ ${broken} broken link(s):${RESET}`);
  for (const i of issues) console.log(`  ${RED}—${RESET} ${i}`);
  process.exit(1);
}
console.log(`${GREEN}✓ All links resolve.${RESET}`);
