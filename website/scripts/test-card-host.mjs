#!/usr/bin/env node
/**
 * test-card-host.mjs — gate for the Afar Messages card fallback at /c/v1.
 *
 * Checks the committed state, then proves each check bites by mutating an
 * in-memory copy and requiring a specific CardHostError:
 *   1. public/c/v1.html and card-host/headers.json are the imported bytes
 *      (size, sha256 and git blob from card-host/import-receipt.json), and the
 *      built dist/c/v1.html is identical.
 *   2. firebase.json serves /c/v1 with the contract's route-scoped headers,
 *      after "**", with no redirect or rewrite in the way, and no card hash in
 *      any other route's CSP.
 *   3. The sitemap leaves /c/v1 out, and no association file ships, so
 *      universal links stay off.
 *
 * Header precedence (last match wins) is proven separately against the
 * Firebase Hosting emulator: npm run test:card-host:emulator.
 */
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import {
  CARD_CONTRACT_FILE,
  CARD_DIST_FILE,
  CARD_PUBLIC_FILE,
  CARD_ROUTE,
  CardHostError,
  WEBSITE_ROOT,
  globToRegExp,
  isCardFallbackDistFile,
  loadReceipt,
  validateCardHosting,
  validateReceipt,
  verifyImportedBytes
} from "./lib/card-host.mjs";

const REPO_ROOT = join(WEBSITE_ROOT, "..");
const firebase = JSON.parse(readFileSync(join(REPO_ROOT, "firebase.json"), "utf8"));
const marketing = firebase.hosting.find((site) => site.target === "marketing");
assert.ok(marketing, "firebase.json must define the marketing hosting target");

const receipt = loadReceipt();
const pageBytes = readFileSync(join(WEBSITE_ROOT, CARD_PUBLIC_FILE));
const contractBytes = readFileSync(join(WEBSITE_ROOT, CARD_CONTRACT_FILE));
verifyImportedBytes(receipt, CARD_PUBLIC_FILE, pageBytes);
verifyImportedBytes(receipt, CARD_CONTRACT_FILE, contractBytes);
const html = pageBytes.toString("utf8");
const contract = JSON.parse(contractBytes.toString("utf8"));
const effective = validateCardHosting({ marketing, contract, html });

// Built output: the page ships unchanged and stays out of the sitemap.
const dist = join(WEBSITE_ROOT, "dist");
assert.ok(existsSync(dist), "dist/ must exist; run npm run build first");
const built = join(WEBSITE_ROOT, CARD_DIST_FILE);
assert.ok(existsSync(built), `${CARD_DIST_FILE} is missing from the build`);
assert.ok(
  readFileSync(built).equals(pageBytes),
  `${CARD_DIST_FILE} must be byte-identical to ${CARD_PUBLIC_FILE}`
);
assert.equal(isCardFallbackDistFile(built, { receipt }), true);
assert.equal(isCardFallbackDistFile(join(dist, "index.html"), { receipt }), false);
const sitemap = readFileSync(join(dist, "sitemap.xml"), "utf8");
assert.ok(
  !sitemap.includes(`https://burnbar.ai${CARD_ROUTE}<`),
  "the sitemap must not list the card fallback"
);

// Universal links stay off until entitlement, profile and device are proven.
for (const file of [
  "public/.well-known/apple-app-site-association",
  "public/apple-app-site-association"
]) {
  assert.ok(
    !existsSync(join(WEBSITE_ROOT, file)),
    `${file} must not ship yet; universal links stay off`
  );
}

// ── Mutations: every guard must fail with its own message. ──────────────────
const clone = (value) => structuredClone(value);
let rejected = 0;
function rejects(label, run, pattern) {
  rejected += 1;
  assert.throws(
    run,
    (error) => error instanceof CardHostError && pattern.test(error.message),
    label
  );
}
const marketingWith = (edit) => {
  const copy = clone(marketing);
  edit(copy);
  return copy;
};
const cardRule = (copy) => copy.headers.find((rule) => rule.source === CARD_ROUTE);
const setHeader = (rule, key, value) => {
  const header = rule.headers.find((entry) => entry.key === key);
  if (header) header.value = value;
  else rule.headers.push({ key, value });
};
const valid = (overrides) => validateCardHosting({ marketing, contract, html, ...overrides });

// Receipt shape.
rejects(
  "receipt: wrong commit",
  () => validateReceipt({ ...clone(receipt), source: { ...receipt.source, commit: "84cb19b" } }),
  /source\.commit/
);
rejects(
  "receipt: wrong repository",
  () =>
    validateReceipt({
      ...clone(receipt),
      source: { ...receipt.source, repository: "someone/else" }
    }),
  /source\.repository/
);
rejects(
  "receipt: extra file",
  () =>
    validateReceipt({
      ...clone(receipt),
      files: [...receipt.files, { ...receipt.files[0], path: "public/x.html" }]
    }),
  /exactly 2 files/
);
rejects(
  "receipt: duplicate file",
  () => validateReceipt({ ...clone(receipt), files: [receipt.files[0], receipt.files[0]] }),
  /twice/
);
rejects(
  "receipt: unexpected path",
  () =>
    validateReceipt({
      ...clone(receipt),
      files: [{ ...receipt.files[0], path: "../x" }, receipt.files[1]]
    }),
  /unexpected file/
);
rejects(
  "receipt: uppercase sha",
  () =>
    validateReceipt({
      ...clone(receipt),
      files: [
        { ...receipt.files[0], sha256: receipt.files[0].sha256.toUpperCase() },
        receipt.files[1]
      ]
    }),
  /sha256/
);
rejects(
  "receipt: string size",
  () =>
    validateReceipt({
      ...clone(receipt),
      files: [{ ...receipt.files[0], bytes: "10125" }, receipt.files[1]]
    }),
  /bytes/
);
rejects("receipt: not an object", () => validateReceipt([]), /JSON object/);

// Bytes.
const flipped = Buffer.from(pageBytes);
flipped[flipped.length - 2] ^= 1;
rejects(
  "bytes: one flipped byte",
  () => verifyImportedBytes(receipt, CARD_PUBLIC_FILE, flipped),
  /sha256/
);
rejects(
  "bytes: appended newline",
  () =>
    verifyImportedBytes(receipt, CARD_PUBLIC_FILE, Buffer.concat([pageBytes, Buffer.from("\n")])),
  /bytes; the receipt pins/
);

// Page and contract coherence.
rejects(
  "page: edited script",
  () => valid({ html: html.replace("use strict", "use  strict") }),
  /does not cover/
);
rejects(
  "page: external script",
  () => valid({ html: html.replace("</body>", '<script src="/x.js"></script></body>') }),
  /exactly one inline script/
);
rejects(
  "page: meta CSP drift",
  () => valid({ html: html.replace("form-action 'none'\">", "form-action 'self'\">") }),
  /meta CSP/
);

// Routing.
rejects(
  "routing: cleanUrls off",
  () => valid({ marketing: marketingWith((m) => (m.cleanUrls = false)) }),
  /cleanUrls/
);
rejects(
  "routing: trailing slash on",
  () => valid({ marketing: marketingWith((m) => (m.trailingSlash = true)) }),
  /trailingSlash/
);
rejects(
  "routing: redirect",
  () =>
    valid({
      marketing: marketingWith((m) =>
        m.redirects.push({ source: "/c/**", destination: "/", type: 301 })
      )
    }),
  /redirect \/c\/\*\* must not match/
);
rejects(
  "routing: rewrite",
  () =>
    valid({
      marketing: marketingWith((m) =>
        m.rewrites.unshift({ source: "/c/v1", destination: "/index.html" })
      )
    }),
  /rewrite \/c\/v1 must not match/
);
rejects(
  "routing: regex redirect",
  () =>
    valid({
      marketing: marketingWith((m) =>
        m.redirects.push({ regex: "^/c/v1\\.html$", destination: "/", type: 301 })
      )
    }),
  /must not match \/c\/v1\.html/
);

// Header rule.
rejects(
  "headers: rule missing",
  () =>
    valid({
      marketing: marketingWith(
        (m) => (m.headers = m.headers.filter((r) => r.source !== CARD_ROUTE))
      )
    }),
  /exactly one \/c\/v1 rule/
);
rejects(
  "headers: rule before **",
  () =>
    valid({
      marketing: marketingWith((m) =>
        m.headers.unshift(m.headers.splice(m.headers.indexOf(cardRule(m)), 1)[0])
      )
    }),
  /after "\*\*"/
);
rejects(
  "headers: CSP widened",
  () =>
    valid({
      marketing: marketingWith((m) =>
        setHeader(
          cardRule(m),
          "Content-Security-Policy",
          contract.routes[CARD_ROUTE].headers["Content-Security-Policy"].replace(
            "default-src 'none'",
            "default-src 'self'"
          )
        )
      )
    }),
  /Content-Security-Policy must be/
);
rejects(
  "headers: no-cache instead of no-store",
  () =>
    valid({ marketing: marketingWith((m) => setHeader(cardRule(m), "Cache-Control", "no-cache")) }),
  /Cache-Control must be/
);
rejects(
  "headers: referrer leaks",
  () =>
    valid({
      marketing: marketingWith(
        (m) =>
          (cardRule(m).headers = cardRule(m).headers.filter((h) => h.key !== "Referrer-Policy"))
      )
    }),
  /Referrer-Policy must be/
);
rejects(
  "headers: indexable",
  () =>
    valid({
      marketing: marketingWith(
        (m) => (cardRule(m).headers = cardRule(m).headers.filter((h) => h.key !== "X-Robots-Tag"))
      )
    }),
  /X-Robots-Tag must be/
);
rejects(
  "headers: content type override",
  () =>
    valid({
      marketing: marketingWith((m) => setHeader(cardRule(m), "Content-Type", "text/plain"))
    }),
  /Content-Type/
);
rejects(
  "headers: permissions weakened",
  () =>
    valid({
      marketing: marketingWith((m) => setHeader(m.headers[0], "Permissions-Policy", "camera=()"))
    }),
  /Permissions-Policy must deny microphone/
);
rejects(
  "headers: HSTS weakened",
  () =>
    valid({
      marketing: marketingWith((m) =>
        setHeader(m.headers[0], "Strict-Transport-Security", "max-age=60")
      )
    }),
  /HSTS/
);
rejects(
  "headers: unreviewed inherited header",
  () =>
    valid({
      marketing: marketingWith((m) => setHeader(m.headers[0], "Access-Control-Allow-Origin", "*"))
    }),
  /inherits Access-Control-Allow-Origin/
);
rejects(
  "headers: inherited framing relaxed",
  () =>
    valid({
      marketing: marketingWith((m) => setHeader(m.headers[0], "X-Frame-Options", "SAMEORIGIN"))
    }),
  /inherits X-Frame-Options/
);
rejects(
  "headers: card hash in site CSP",
  () =>
    valid({
      marketing: marketingWith((m) =>
        setHeader(
          m.headers[0],
          "Content-Security-Policy",
          `${m.headers[0].headers.find((h) => h.key === "Content-Security-Policy").value} 'sha256-7pvWBAN4b/f1BrKHfOsVLJxyf62XUDl5PcSLp3cqc1E='`
        )
      )
    }),
  /contains a card hash/
);
rejects("glob: unsupported syntax", () => globToRegExp("/c/{v1,v2}"), /unsupported glob syntax/);

// The glob reading must agree with firebase.json's own rules.
assert.ok(globToRegExp("**/*.@(js|mjs)").test("/a/b.mjs"));
assert.ok(globToRegExp("**/*.@(js|mjs)").test("/b.js"));
assert.ok(!globToRegExp("**/*.@(js|mjs)").test(CARD_ROUTE));
assert.ok(globToRegExp("/downloads/sbom-*.json").test("/downloads/sbom-macos.json"));
assert.ok(!globToRegExp("/downloads/sbom-*.json").test("/downloads/x/sbom-a.json"));

console.log(
  `✓ card host: ${CARD_ROUTE} serves the imported bytes (${pageBytes.length} B, sha256 ${receipt.files[0].sha256.slice(0, 12)}…) ` +
    `with ${effective.size} route headers; ${rejected} mutations rejected; universal links off.`
);
