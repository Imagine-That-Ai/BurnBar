#!/usr/bin/env node
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { isReviewedCollectorOrigin } from "../../analytics/collector-origins.mjs";

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
// content: the daily router-rundown JSON-LD embeds research data that is
// refreshed only by the explicit `npm run research` command. Normal website
// builds consume the committed snapshot, so CSP checks stay deterministic.
// Skip inert data blocks; every executable script (no type, module, importmap,
// speculationrules, ...) stays gated.
const INERT_DATA_BLOCK_TYPE = /\btype\s*=\s*["']?(?:application\/(?:ld\+)?json|text\/plain)\b/i;

function inlineHashesFromDist() {
  assert.ok(
    statSync(DIST).isDirectory(),
    `${relative(REPO_ROOT, DIST)} must exist; run npm --prefix website run build:offline first`
  );
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
        }…) — the generated CSP (script-src 'self' + hashes) would block that import at runtime; bundle the dependency instead of hashing a script this CSP will break`
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
    styleAttributeHashes: sortedSources(styleAttributeHashes)
  };
}

function buildMarketingCsp(
  { scriptHashes, styleElementHashes, styleAttributeHashes },
  { imgSrc = [], scriptSrc = [], frameSrc = [], connectSrc = [], formAction = [] } = {}
) {
  const directives = [
    "default-src 'self'",
    `img-src 'self' data:${imgSrc.length > 0 ? ` ${imgSrc.join(" ")}` : ""}`,
    "style-src 'self'",
    `style-src-elem 'self' ${styleElementHashes.join(" ")}`,
    `style-src-attr 'unsafe-hashes' ${styleAttributeHashes.join(" ")}`,
    `script-src 'self' ${scriptHashes.join(" ")}${scriptSrc.length > 0 ? ` ${scriptSrc.join(" ")}` : ""}`,
    "font-src 'self' data:",
    // Opt-in analytics POSTs to a first-party collector URL (same origin by
    // default). The browser never talks to api2.amplitude.com. Extra collector
    // origins, if any, are passed via connectSrc.
    `connect-src 'self'${connectSrc.length > 0 ? ` ${connectSrc.join(" ")}` : ""}`,
    "frame-ancestors 'none'",
    "base-uri 'self'",
    `form-action 'self'${formAction.length > 0 ? ` ${formAction.join(" ")}` : ""}`
  ];
  if (frameSrc.length > 0) {
    directives.splice(7, 0, `frame-src ${frameSrc.join(" ")}`);
  }
  return directives.join("; ");
}

function parseCollectorUrl(raw) {
  const trimmed = (raw ?? "").trim();
  if (!trimmed) return null;
  let url;
  try {
    url = new URL(trimmed);
  } catch {
    throw new Error(`PUBLIC_ANALYTICS_COLLECTOR_URL must be an absolute URL, got: ${trimmed}`);
  }
  const local = /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(url.origin);
  if (url.protocol !== "https:" && !local) {
    throw new Error(
      `PUBLIC_ANALYTICS_COLLECTOR_URL must be https (or http localhost / 127.0.0.1), got: ${trimmed}`
    );
  }
  if (!isReviewedCollectorOrigin(trimmed)) {
    throw new Error(
      `PUBLIC_ANALYTICS_COLLECTOR_URL must be a reviewed collector origin, got: ${trimmed}`
    );
  }
  return url;
}

function extraCollectorConnectSrc(env = process.env) {
  const url = parseCollectorUrl(env.PUBLIC_ANALYTICS_COLLECTOR_URL);
  if (!url) return [];
  // CSP `'self'` is exact-origin. A page on burnbar.ai cannot POST to
  // burnbar.web.app (or www) unless that origin is listed, even when it is
  // first-party.
  return [url.origin];
}

function expectedMarketingCsps(hashes, { includeCollector = false, env = process.env } = {}) {
  // `--check` compares the committed dark default. Collector origins are
  // applied only by `--write` at deploy time when PUBLIC_ANALYTICS_COLLECTOR_URL
  // is set, so PR verify stays green without baking a Worker URL into git.
  // Always validate a nonempty URL, even during `--check` / dark CSP.
  // A typo must fail the deploy, not silently omit connect-src.
  const parsedCollectorOrigins = extraCollectorConnectSrc(env);
  const collectorOrigins = includeCollector ? parsedCollectorOrigins : [];
  const firebaseAuthSources = {
    imgSrc: ["https://*.googleusercontent.com"],
    scriptSrc: [
      "https://apis.google.com",
      "https://www.google.com/recaptcha/",
      "https://www.gstatic.com/recaptcha/"
    ],
    frameSrc: [
      "https://*.firebaseapp.com",
      "https://accounts.google.com",
      "https://appleid.apple.com",
      "https://www.google.com/recaptcha/"
    ],
    connectSrc: [
      "https://apis.google.com",
      "https://*.googleapis.com",
      "https://*.firebaseio.com",
      "https://*.cloudfunctions.net",
      "https://identitytoolkit.googleapis.com",
      "https://securetoken.googleapis.com",
      "https://firebaseinstallations.googleapis.com",
      "https://firebaseappcheck.googleapis.com",
      "https://content-firebaseappcheck.googleapis.com",
      "https://www.google.com",
      "https://www.gstatic.com",
      ...collectorOrigins
    ],
    formAction: ["https://accounts.google.com", "https://appleid.apple.com"]
  };
  // The BurnBench Arena vote page embeds anonymized artifacts in cross-origin
  // iframes served from the dedicated arena-artifacts hosting site (locked CSP,
  // CORP cross-origin). frame-src must allow that origin site-wide so the vote
  // page can frame artifacts; the artifacts site's own CSP disables their
  // network access, so this does not widen the marketing site's attack surface.
  const arenaArtifactFrameSrc = [
    "https://burnbar-arena-artifacts.web.app",
    "https://burnbar-arena-artifacts.firebaseapp.com"
  ];
  // The vote page also calls the two Arena callables (arenaMatchup, arenaVote)
  // directly from the client, and now requires Firebase Auth sign-in (Google +
  // Apple) via a soft gate. It needs the full auth-capable CSP (identity toolkit,
  // securetoken, popup/redirect frames, provider form-actions) merged with the
  // arena-artifacts frame-src and the callable connect-src.
  const arenaVotePage = {
    imgSrc: firebaseAuthSources.imgSrc,
    scriptSrc: firebaseAuthSources.scriptSrc,
    frameSrc: [...arenaArtifactFrameSrc, ...firebaseAuthSources.frameSrc],
    connectSrc: [
      "https://us-central1-burnbar.cloudfunctions.net",
      ...firebaseAuthSources.connectSrc.filter((source) => !collectorOrigins.includes(source)),
      ...collectorOrigins
    ],
    formAction: firebaseAuthSources.formAction
  };
  return new Map([
    [
      "**",
      buildMarketingCsp(hashes, { frameSrc: arenaArtifactFrameSrc, connectSrc: collectorOrigins })
    ],
    ["/bench/arena/vote", buildMarketingCsp(hashes, arenaVotePage)],
    ["/link", buildMarketingCsp(hashes, firebaseAuthSources)],
    ["/hermes/connect", buildMarketingCsp(hashes, firebaseAuthSources)],
    ["/subscribe", buildMarketingCsp(hashes, firebaseAuthSources)]
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
      .filter(Boolean)
  );
}

function loadFirebaseConfig() {
  return JSON.parse(readFileSync(FIREBASE_JSON, "utf8"));
}

function main(argv = process.argv.slice(2)) {
  const write = argv.includes("--write");
  const check = argv.includes("--check") || !write;
  const hashes = inlineHashesFromDist();
  const expected = expectedMarketingCsps(hashes, { includeCollector: write });
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
      `PASS: updated ${expected.size} marketing CSP header(s) with ${hashes.scriptHashes.length} script, ${hashes.styleElementHashes.length} style element, and ${hashes.styleAttributeHashes.length} style attribute hash(es).`
    );
    return;
  }

  for (const [source, value] of expected) {
    const csp = cspHeaders.get(source);
    assert.ok(csp, `marketing ${source} headers must include Content-Security-Policy`);
    assert.equal(
      csp.value,
      value,
      `firebase.json marketing ${source} CSP is stale; run npm --prefix website run csp:update after build:offline`
    );
    assert.ok(
      !/\bunsafe-inline\b/.test(csp.value),
      `marketing ${source} CSP must not contain unsafe-inline`
    );
    assert.match(csp.value, /script-src 'self' 'sha256-/);
    assert.match(csp.value, /style-src-elem 'self' 'sha256-/);
    assert.match(csp.value, /style-src-attr 'unsafe-hashes' 'sha256-/);
  }
  if (check) {
    console.log(
      `PASS: ${expected.size} marketing CSP header(s) cover ${hashes.scriptHashes.length} script, ${hashes.styleElementHashes.length} style element, and ${hashes.styleAttributeHashes.length} style attribute hash(es); unsafe-inline absent.`
    );
  }
}

export { extraCollectorConnectSrc, expectedMarketingCsps, parseCollectorUrl };

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  try {
    return import.meta.url === pathToFileURL(entry).href;
  } catch {
    return false;
  }
}

if (invokedDirectly()) {
  main();
}
