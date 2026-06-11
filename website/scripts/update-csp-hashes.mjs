#!/usr/bin/env node
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const WEBSITE_ROOT = join(HERE, "..");
const REPO_ROOT = join(WEBSITE_ROOT, "..");
const DIST = join(WEBSITE_ROOT, "dist");
const FIREBASE_JSON = join(REPO_ROOT, "firebase.json");
const CSP_HEADER = "Content-Security-Policy";

function walk(dir, out = []) {
  for (const entry of readdirSync(dir)) {
    const file = join(dir, entry);
    if (statSync(file).isDirectory()) walk(file, out);
    else out.push(file);
  }
  return out;
}

function sha256Source(value) {
  return `'sha256-${createHash("sha256").update(value).digest("base64")}'`;
}

function sortedSources(values) {
  return [...values].sort((a, b) => a.localeCompare(b));
}

// Fail-closed (perf round 2, website-013): hashing an inline script that
// imports cross-origin code would produce a CSP that allows the script to
// START but blocks its import at runtime — the exact silent-failure mode that
// killed the esm.sh pretext module in production while every QA pass on
// dev/preview rendered it. Refuse to generate such a CSP. From-aware so
// named-binding static imports (`import { x } from "https://…"`) are caught.
const CROSS_ORIGIN_IMPORT = /\b(?:import|from)\s*\(?\s*["'`](?:https?:)?\/\/(?!burnbar\.ai)/;

// CSP `script-src` only governs EXECUTABLE script elements. Data blocks —
// `type="application/ld+json"` structured data, plain JSON payloads — are
// inert per the HTML spec: browsers never run them and CSP never consults
// their hashes. Hashing them anyway coupled the committed CSP to volatile
// content: the daily router-rundown JSON-LD embeds research data that
// `npm run build` refreshes via run-research when API keys + compiled
// functions are present (local), while CI builds from the committed
// snapshot — so csp:check diverged across environments. Skip them; every
// executable script (no type, module, importmap, speculationrules, …)
// stays gated.
const INERT_DATA_BLOCK_TYPE = /\btype\s*=\s*["']?(?:application\/(?:ld\+)?json|text\/plain)\b/i;

function inlineHashesFromDist() {
  assert.ok(statSync(DIST).isDirectory(), `${relative(REPO_ROOT, DIST)} must exist; run npm --prefix website run build:offline first`);
  const scriptHashes = new Set();
  const styleElementHashes = new Set();
  const styleAttributeHashes = new Set();

  for (const file of walk(DIST).filter((candidate) => candidate.endsWith(".html"))) {
    const body = readFileSync(file, "utf8");
    for (const match of body.matchAll(/<script(?![^>]*\bsrc=)([^>]*)>([\s\S]*?)<\/script>/gi)) {
      if (INERT_DATA_BLOCK_TYPE.test(match[1])) continue;
      assert.ok(
        !CROSS_ORIGIN_IMPORT.test(match[2]),
        `${relative(REPO_ROOT, file)}: inline script imports cross-origin code (${
          match[2].match(CROSS_ORIGIN_IMPORT)?.[0]
        }…) — the generated CSP (script-src 'self' + hashes) would block that import at runtime; bundle the dependency instead of hashing a script this CSP will break`,
      );
      scriptHashes.add(sha256Source(match[2]));
    }
    for (const match of body.matchAll(/<style\b[^>]*>([\s\S]*?)<\/style>/gi)) {
      styleElementHashes.add(sha256Source(match[1]));
    }
    for (const match of body.matchAll(/\sstyle=["']([^"']+)["']/gi)) {
      styleAttributeHashes.add(sha256Source(match[1]));
    }
  }

  return {
    scriptHashes: sortedSources(scriptHashes),
    styleElementHashes: sortedSources(styleElementHashes),
    styleAttributeHashes: sortedSources(styleAttributeHashes),
  };
}

function buildMarketingCsp(
  { scriptHashes, styleElementHashes, styleAttributeHashes },
  {
    imgSrc = [],
    scriptSrc = [],
    frameSrc = [],
    connectSrc = [],
    formAction = [],
  } = {},
) {
  const directives = [
    "default-src 'self'",
    `img-src 'self' data:${imgSrc.length > 0 ? ` ${imgSrc.join(" ")}` : ""}`,
    "style-src 'self'",
    `style-src-elem 'self' ${styleElementHashes.join(" ")}`,
    `style-src-attr 'unsafe-hashes' ${styleAttributeHashes.join(" ")}`,
    `script-src 'self' ${scriptHashes.join(" ")}${scriptSrc.length > 0 ? ` ${scriptSrc.join(" ")}` : ""}`,
    "font-src 'self' data:",
    `connect-src 'self'${connectSrc.length > 0 ? ` ${connectSrc.join(" ")}` : ""}`,
    "frame-ancestors 'none'",
    "base-uri 'self'",
    `form-action 'self'${formAction.length > 0 ? ` ${formAction.join(" ")}` : ""}`,
  ];
  if (frameSrc.length > 0) {
    directives.splice(7, 0, `frame-src ${frameSrc.join(" ")}`);
  }
  return directives.join("; ");
}

function expectedMarketingCsps(hashes) {
  return new Map([
    ["**", buildMarketingCsp(hashes)],
    [
      "/link",
      buildMarketingCsp(hashes, {
        imgSrc: ["https://*.googleusercontent.com"],
        scriptSrc: ["https://www.google.com", "https://www.gstatic.com"],
        frameSrc: ["https://*.google.com"],
        connectSrc: [
          "https://*.googleapis.com",
          "https://*.firebaseio.com",
          "https://*.cloudfunctions.net",
          "http://localhost:5001",
          "http://localhost:9099",
        ],
      }),
    ],
    [
      "/hermes/connect",
      buildMarketingCsp(hashes, {
        imgSrc: ["https://*.googleusercontent.com"],
        frameSrc: ["https://*.google.com", "https://accounts.google.com", "https://appleid.apple.com"],
        connectSrc: [
          "https://*.googleapis.com",
          "https://*.firebaseio.com",
          "https://*.cloudfunctions.net",
          "https://identitytoolkit.googleapis.com",
          "https://securetoken.googleapis.com",
        ],
        formAction: ["https://accounts.google.com", "https://appleid.apple.com"],
      }),
    ],
  ]);
}

function marketingCspHeaders(firebaseConfig) {
  const marketing = firebaseConfig.hosting.find((entry) => entry.target === "marketing");
  assert.ok(marketing, "firebase.json must contain the marketing hosting target");
  return new Map(
    marketing.headers
      .map((entry) => {
        const csp = entry.headers?.find((header) => header.key === CSP_HEADER);
        return csp ? [entry.source, csp] : undefined;
      })
      .filter(Boolean),
  );
}

function loadFirebaseConfig() {
  return JSON.parse(readFileSync(FIREBASE_JSON, "utf8"));
}

function main(argv = process.argv.slice(2)) {
  const write = argv.includes("--write");
  const check = argv.includes("--check") || !write;
  const hashes = inlineHashesFromDist();
  const expected = expectedMarketingCsps(hashes);
  const config = loadFirebaseConfig();
  const cspHeaders = marketingCspHeaders(config);

  if (write) {
    for (const [source, value] of expected) {
      const csp = cspHeaders.get(source);
      assert.ok(csp, `marketing ${source} headers must include Content-Security-Policy`);
      csp.value = value;
    }
    writeFileSync(FIREBASE_JSON, `${JSON.stringify(config, null, 2)}\n`, "utf8");
    console.log(
      `PASS: updated ${expected.size} marketing CSP header(s) with ${hashes.scriptHashes.length} script, ${hashes.styleElementHashes.length} style element, and ${hashes.styleAttributeHashes.length} style attribute hash(es).`,
    );
    return;
  }

  for (const [source, value] of expected) {
    const csp = cspHeaders.get(source);
    assert.ok(csp, `marketing ${source} headers must include Content-Security-Policy`);
    assert.equal(
      csp.value,
      value,
      `firebase.json marketing ${source} CSP is stale; run npm --prefix website run csp:update after build:offline`,
    );
    assert.ok(!/\bunsafe-inline\b/.test(csp.value), `marketing ${source} CSP must not contain unsafe-inline`);
    assert.match(csp.value, /script-src 'self' 'sha256-/);
    assert.match(csp.value, /style-src-elem 'self' 'sha256-/);
    assert.match(csp.value, /style-src-attr 'unsafe-hashes' 'sha256-/);
  }
  if (check) {
    console.log(
      `PASS: ${expected.size} marketing CSP header(s) cover ${hashes.scriptHashes.length} script, ${hashes.styleElementHashes.length} style element, and ${hashes.styleAttributeHashes.length} style attribute hash(es); unsafe-inline absent.`,
    );
  }
}

main();
