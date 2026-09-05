#!/usr/bin/env node
/* Build a sitemap.xml from the routes we publish.
 * Runs after `astro build` writes to dist/.
 */

import { readdirSync, statSync, writeFileSync, existsSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const SITE = "https://burnbar.ai";
// fileURLToPath, not `.pathname`: a checkout under a directory with a space in
// its name resolves to "…%20…" through `.pathname`, and the sitemap step then
// exits with "dist/ does not exist" on an otherwise successful build.
const DIST = fileURLToPath(new URL("../dist", import.meta.url));
// Pages we do not want indexed: the 404 page and the noindex'd auth-utility
// surfaces (device linking + Hermes account connect).
const EXCLUDE = ["/404", "/link", "/hermes/connect"];

const now = new Date().toISOString().slice(0, 10);

function walk(dir) {
  const out = [];
  for (const entry of readdirSync(dir)) {
    const p = join(dir, entry);
    if (statSync(p).isDirectory()) {
      out.push(...walk(p));
    } else if (entry === "index.html") {
      const rel = "/" + relative(DIST, dir).replace(/\\/g, "/");
      out.push(rel === "/." ? "/" : rel);
    }
  }
  return out;
}

if (!existsSync(DIST)) {
  console.error("dist/ does not exist — run `astro build` first.");
  process.exit(1);
}

const routes = walk(DIST)
  .map((r) => (r === "/." ? "/" : r))
  .filter((r) => !EXCLUDE.includes(r))
  .sort();

const priority = (r) => {
  if (r === "/") return 1.0;
  if (r === "/download" || r === "/product") return 0.9;
  if (r === "/providers" || r === "/pricing" || r === "/privacy") return 0.85;
  if (r.startsWith("/legal")) return 0.4;
  return 0.7;
};

const changefreq = (r) => {
  if (r === "/" || r === "/download") return "weekly";
  if (r.startsWith("/legal")) return "yearly";
  return "monthly";
};

const xml = [
  '<?xml version="1.0" encoding="UTF-8"?>',
  '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
  ...routes.map(
    (r) =>
      "  <url>\n" +
      // Slash-less URLs: firebase.json sets "trailingSlash": false for the
      // marketing target, so the slashed form 301-redirects. Sitemap entries
      // must match the served (and canonical) form exactly.
      `    <loc>${SITE}${r === "/" ? "/" : r}</loc>\n` +
      `    <lastmod>${now}</lastmod>\n` +
      `    <changefreq>${changefreq(r)}</changefreq>\n` +
      `    <priority>${priority(r).toFixed(2)}</priority>\n` +
      "  </url>"
  ),
  "</urlset>",
  ""
].join("\n");

writeFileSync(join(DIST, "sitemap.xml"), xml);
console.log(`✓ sitemap.xml — ${routes.length} routes`);
