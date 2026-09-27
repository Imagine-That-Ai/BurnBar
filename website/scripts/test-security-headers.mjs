#!/usr/bin/env node
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const firebase = JSON.parse(readFileSync(path.join(repoRoot, "firebase.json"), "utf8"));
const marketing = firebase.hosting.find((site) => site.target === "marketing");

assert.ok(marketing, "firebase.json must define the marketing hosting target");

function headersFor(source) {
  const rule = marketing.headers.find((candidate) => candidate.source === source);
  assert.ok(rule, `marketing headers must define ${source}`);
  return new Map(rule.headers.map((header) => [header.key, header.value]));
}

const defaults = headersFor("**");
assert.equal(defaults.get("Cross-Origin-Embedder-Policy"), "require-corp");
assert.equal(defaults.get("Cross-Origin-Opener-Policy"), "same-origin");
assert.equal(defaults.get("Cross-Origin-Resource-Policy"), "same-origin");

for (const source of ["/bench/arena/vote", "/link", "/beta", "/hermes/connect", "/subscribe"]) {
  const headers = headersFor(source);
  assert.equal(headers.get("Cross-Origin-Embedder-Policy"), "unsafe-none");
  assert.equal(headers.get("Cross-Origin-Opener-Policy"), "same-origin-allow-popups");
  assert.equal(headers.get("Cross-Origin-Resource-Policy"), "same-origin");
  assert.doesNotMatch(
    headers.get("Content-Security-Policy") ?? "",
    /http:\/\/(?:localhost|127\.0\.0\.1|\[::1\])/u,
    `${source} production CSP must not allow Firebase emulator endpoints`,
  );
}

const platformPage = readFileSync(
  path.join(repoRoot, "website", "src", "pages", "platforms", "index.astro"),
  "utf8"
);
assert.doesNotMatch(
  platformPage,
  /\b(?:10(?:\.\d{1,3}){3}|192\.168(?:\.\d{1,3}){2}|172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2})(?::\d+)?\b/,
  "public marketing copy must not expose private-network addresses"
);

console.log("security-headers: 7 invariant groups passed");
