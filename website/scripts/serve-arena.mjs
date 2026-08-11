#!/usr/bin/env node
/**
 * Local static server for Arena artifact bundles.
 *
 * The production artifacts site (burnbar-arena-artifacts.web.app) sets
 * `frame-ancestors` to only allow production origins, so a page served from
 * `http://127.0.0.1:4321` (astro dev) cannot embed prod artifact iframes.
 *
 * This tiny server mirrors the arena-public/ directory on port 5506 with a
 * permissive `frame-ancestors` so the dev vote page can load real artifacts.
 *
 * Usage:  node scripts/serve-arena.mjs
 * Then:   open http://127.0.0.1:4321/bench/arena/vote
 *         (bench-arena.ts auto-detects 127.0.0.1 and uses :5506)
 */
import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { join, extname, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "arena-public");
const PORT = 5506;

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".gif": "image/gif",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf",
  ".ico": "image/x-icon",
  ".webp": "image/webp",
  ".avif": "image/avif",
};

const CSP = [
  "default-src 'none'",
  "script-src 'self' 'unsafe-inline'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob:",
  "font-src 'self' data:",
  "connect-src 'none'",
  // Permissive in dev: allow any localhost origin to embed artifacts.
  "frame-ancestors http://127.0.0.1:* http://localhost:* https://127.0.0.1:* https://localhost:*",
  "base-uri 'none'",
  "form-action 'none'",
].join("; ");

const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://127.0.0.1:${PORT}`);
    let path = normalize(decodeURIComponent(url.pathname));
    if (path === "/" || path === "/") path = "/index.html";
    // Prevent path traversal.
    const full = join(ROOT, path);
    if (!full.startsWith(ROOT)) {
      res.writeHead(403);
      res.end("Forbidden");
      return;
    }
    const s = await stat(full).catch(() => null);
    if (!s || !s.isFile()) {
      res.writeHead(404);
      res.end("Not found");
      return;
    }
    const data = await readFile(full);
    res.writeHead(200, {
      "Content-Type": MIME[extname(full)] ?? "application/octet-stream",
      "Content-Security-Policy": CSP,
      "Cross-Origin-Resource-Policy": "cross-origin",
      "Cross-Origin-Embedder-Policy": "unsafe-none",
      "X-Content-Type-Options": "nosniff",
      "Referrer-Policy": "no-referrer",
      "Cache-Control": "no-cache",
    });
    res.end(data);
  } catch (err) {
    res.writeHead(500);
    res.end(String(err));
  }
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`Arena artifacts server: http://127.0.0.1:${PORT}  (serving ${ROOT})`);
});
