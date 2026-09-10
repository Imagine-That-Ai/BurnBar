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
import { fileURLToPath, pathToFileURL } from "node:url";

// fileURLToPath, not `.pathname`: a checkout under a directory with a space in
// its name (or any character a URL percent-encodes) resolves to "…%20…" through
// `.pathname`, and every fs call against it fails with "dist/ does not exist".
const DIST = fileURLToPath(new URL("../dist", import.meta.url));
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
      const rel =
        "/" +
        relative(DIST, p)
          .replace(/\\/g, "/")
          .replace(/\.html$/, "");
      set.add(rel);
    }
  }
  return set;
}

function hasAsset(href) {
  // /favicon.svg, /og/default.svg, /robots.txt, /sitemap.xml, /_assets/*
  // href arrives URL-encoded (e.g. "/downloads/My%20Report.pdf") while the
  // dist/ tree holds the decoded filename, so decode before joining. A
  // malformed percent sequence falls back to the raw href (it won't exist).
  let rel = href.replace(/^\//, "");
  try {
    rel = decodeURIComponent(rel);
  } catch {
    /* keep raw */
  }
  return existsSync(join(DIST, rel));
}

function* hrefs(html) {
  const re = /href\s*=\s*"([^"]+)"/gi;
  let m;
  while ((m = re.exec(html)) !== null) yield m[1];
}

export function isExecutableHrefScheme(href) {
  const normalized = String(href ?? "")
    .trim()
    .toLowerCase();
  return (
    normalized.startsWith("javascript:") ||
    normalized.startsWith("vbscript:") ||
    normalized.startsWith("data:")
  );
}

function shouldSkipHref(href) {
  const normalized = String(href ?? "")
    .trim()
    .toLowerCase();
  return (
    normalized.startsWith("#") || normalized.startsWith("mailto:") || normalized.startsWith("tel:")
  );
}

export function runLinkCheck() {
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
      if (isExecutableHrefScheme(h)) {
        broken++;
        issues.push(`${fileRel}: blocked executable URL scheme ${h}`);
        continue;
      }

      if (shouldSkipHref(h)) continue;

      const href = h.trim();
      const normalizedHref = href.toLowerCase();
      if (normalizedHref.startsWith("http://") || normalizedHref.startsWith("https://")) {
        // Validate format only (no network).
        try {
          new URL(href);
        } catch {
          broken++;
          issues.push(`${fileRel}: malformed URL ${h}`);
        }
        continue;
      }

      // Internal href — strip query/fragment, normalize trailing slash
      const cleaned = href.replace(/[?#].*$/, "").replace(/\/$/, "") || "/";
      if (routes.has(cleaned)) continue;
      if (cleaned !== "/" && routes.has(cleaned + "/")) continue;
      if (hasAsset(cleaned)) continue;

      // macOS DMG is published out-of-band (not copied into dist/ on CI).
      if (/^\/downloads\/OpenBurnBar-.*\.(dmg|zip)$/.test(cleaned)) continue;

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
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  runLinkCheck();
}
