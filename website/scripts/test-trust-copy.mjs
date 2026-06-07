#!/usr/bin/env node
import assert from "node:assert/strict";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");
const REPO_ROOT = join(ROOT, "..");
const DIST = join(ROOT, "dist");
const TRUST_GENERATED = join(ROOT, "src", "data", "trust.generated.ts");
const RUNTIME_READINESS = join(REPO_ROOT, "third_party", "libsignal", "runtime-readiness.json");

const TRUST_ROUTES = [
  join(DIST, "trust", "index.html"),
  join(DIST, "privacy", "index.html")
];

const NETWORK_LINK_RELS = [
  "stylesheet",
  "preload",
  "modulepreload",
  "prefetch",
  "preconnect",
  "dns-prefetch",
  "icon",
  "apple-touch-icon",
  "manifest"
];

const EXTERNAL_PATTERNS = [
  /<script\b[^>]*\bsrc=["'](?:https?:)?\/\//i,
  /<link\b(?=[^>]*\brel=["'][^"']*(?:stylesheet|preload|modulepreload|prefetch|preconnect|dns-prefetch|icon|apple-touch-icon|manifest)[^"']*["'])(?=[^>]*\bhref=["'](?:https?:)?\/\/)/i,
  /<img\b[^>]*\bsrc=["'](?:https?:)?\/\//i,
  /<(?:img|source)\b[^>]*\bsrcset=["'][^"']*(?:https?:)?\/\//i,
  /<iframe\b[^>]*\bsrc=["'](?:https?:)?\/\//i,
  /<source\b[^>]*\bsrc=["'](?:https?:)?\/\//i,
  /<form\b[^>]*\baction=["'](?:https?:)?\/\//i,
  /<(?:button|input)\b[^>]*\bformaction=["'](?:https?:)?\/\//i,
  /<a\b[^>]*\bping=["'][^"']*(?:https?:)?\/\//i,
  /<(?:video|audio)\b[^>]*\bposter=["'](?:https?:)?\/\//i,
  /<meta\b(?=[^>]*\bhttp-equiv=["']refresh["'])(?=[^>]*\bcontent=["'][^"']*\burl\s*=\s*(?:https?:)?\/\/)/i,
  /<(?:use|image)\b[^>]*\b(?:href|xlink:href)=["'](?:https?:)?\/\//i,
  /@import\s+(?:url\(\s*)?["']?(?:https?:)?\/\//i,
  /url\(\s*["']?(?:https?:)?\/\//i,
  /\bfetch\(\s*["'](?:https?:)?\/\//i,
  /\bnavigator\.sendBeacon\(\s*["'](?:https?:)?\/\//i,
  /\bXMLHttpRequest\b/i,
  /\bnew\s+WebSocket\(\s*["'](?:wss?:|https?:)\/\//i,
  /\bnew\s+EventSource\(\s*["'](?:https?:)?\/\//i,
  /\bimport\(\s*["'](?:https?:)?\/\//i,
  /from\s+["'](?:https?:)?\/\//i
];

const TRACKER_TOKENS =
  /\bposthog\b|googletagmanager|gtag\(|plausible\.io|usefathom|umami\.is|hotjar|mixpanel|browser\.sentry-cdn|ingest\.sentry\.io|@sentry\//i;

const NOT_READY_RUNTIME_CLAIMS = [
  /\b(?:relay|gateway)[^.]{0,160}\bnever (?:sees|receives) plaintext\b/i,
  /\bnever reads? message text\b/i,
  /\bnever receives readable message text\b/i,
  /\bboth directions are end-to-end encrypted\b/i,
  /\bend-to-end encrypted\b/i,
  /\bend-to-end[- ]encrypted WebSocket\b/i,
  /\bencrypted end-to-end\b/i,
  /\bencrypted end to end\b/i,
  /\bprivate end to end\b/i,
  /\beverything between them is end-to-end encrypted\b/i,
  /\bno one in the middle can read it\b/i,
  /\bcouldn['’]t peek\b/i,
  /\bwe can['’]t read\b/i,
  /\bservers? never see(?:s)? the content or the key\b/i,
  /\bserver runs (?:nearest-neighbor search|ANN)[^.]{0,160}without reading your content\b/i,
  /\bhosted server never sees\b/i,
  /\bwhat the server never sees\b/i,
];

const ALLOWED_SCRIPT_URL_HOSTS = new Set([
  "accounts.google.com",
  "apis.google.com",
  "firebaseinstallations.googleapis.com",
  "identitytoolkit.googleapis.com",
  "localhost",
  "securetoken.googleapis.com",
  "www.google.com",
  "www.googleapis.com",
  "www.gstatic.com",
  "127.0.0.1",
  "::1",
]);

const ALLOWED_SCRIPT_URL_SUFFIXES = [
  ".cloudfunctions.net",
  ".firebaseio.com",
  ".googleapis.com",
];

function walk(dir, out = []) {
  for (const entry of readdirSync(dir)) {
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) walk(path, out);
    else out.push(path);
  }
  return out;
}

function htmlDecode(value) {
  return value
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)))
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
}

function getAttr(tag, attr) {
  const match = tag.match(new RegExp(`\\b${attr}=["']([^"']+)["']`, "i"));
  return match ? htmlDecode(match[1]) : "";
}

function assertNoNetworkLinkRels(label, body) {
  for (const match of body.matchAll(/<link\b[^>]*>/gi)) {
    const tag = match[0];
    const href = getAttr(tag, "href");
    if (!/^(?:https?:)?\/\//i.test(href)) continue;
    const rels = getAttr(tag, "rel")
      .toLowerCase()
      .split(/\s+/)
      .filter(Boolean);
    const networkRel = rels.find((rel) => NETWORK_LINK_RELS.includes(rel));
    assert.equal(
      networkRel,
      undefined,
      `${label} contains external ${networkRel} link ${JSON.stringify(tag)}`
    );
  }
}

function assertNoExternalNetworkBody(label, body) {
  assertNoNetworkLinkRels(label, body);
  for (const pattern of EXTERNAL_PATTERNS) {
    const match = body.match(pattern);
    assert.equal(
      match,
      null,
      `${label} contains external network reference ${JSON.stringify(match?.[0])}`
    );
  }
  const tracker = body.match(TRACKER_TOKENS);
  assert.equal(tracker, null, `${label} contains tracker token ${JSON.stringify(tracker?.[0])}`);
}

function trimUrlLiteral(raw) {
  return raw.replace(/[\\'"),.;]+$/g, "");
}

function isFirebaseClientAsset(file) {
  return /(^|[/\\])firebaseClient(?:\.|\.js$)/.test(file);
}

function isAllowedScriptUrlLiteral(raw, file) {
  if (
    isFirebaseClientAsset(file) &&
    (
      /^https:\/\/\$\{[^}]+\.(?:config\.)?authDomain\}/.test(raw) ||
      /^https:\/\/\$\{[^}]+\.region\}-\$\{[^}]+\}\.cloudfunctions\.net\//.test(raw) ||
      /^http:\/\/\$\{[^}]+\}$/.test(raw)
    )
  ) {
    return true;
  }
  let parsed;
  try {
    parsed = new URL(raw);
  } catch {
    return false;
  }
  const host = parsed.hostname.toLowerCase();
  if (ALLOWED_SCRIPT_URL_HOSTS.has(host)) return true;
  return ALLOWED_SCRIPT_URL_SUFFIXES.some((suffix) => host.endsWith(suffix));
}

function assertNoDisallowedScriptUrlLiterals(file, body) {
  if (!/\.(?:js|mjs)$/.test(file)) return;
  for (const match of body.matchAll(/https?:\/\/[^\s"'`<>()]+/g)) {
    const url = trimUrlLiteral(match[0]);
    assert.ok(
      isAllowedScriptUrlLiteral(url, file),
      `${relative(ROOT, file)} contains disallowed external URL literal ${JSON.stringify(url)}`
    );
  }
}

function assertNoExternalNetwork(file) {
  const body = readFileSync(file, "utf8");
  assertNoExternalNetworkBody(relative(ROOT, file), body);
  assertNoDisallowedScriptUrlLiterals(file, body);
  if (file.endsWith(".webmanifest")) {
    assertNoWebManifestNetworkBody(relative(ROOT, file), body);
  }
}

function assertBlocked(label, body) {
  assert.throws(() => assertNoExternalNetworkBody(label, body), /external|tracker/);
}

function assertNoWebManifestNetworkBody(label, body) {
  const match = body.match(/"(?:src|href|url)"\s*:\s*["'](?:https?:)?\/\//i);
  assert.equal(match, null, `${label} contains external webmanifest URL ${JSON.stringify(match?.[0])}`);
}

function runtimeReadinessStatus() {
  return JSON.parse(readFileSync(RUNTIME_READINESS, "utf8")).status;
}

function assertNoUnreadyRuntimeClaims(claimFiles) {
  if (runtimeReadinessStatus() === "ready") return;
  for (const file of claimFiles) {
    const label = relative(REPO_ROOT, file);
    const body = htmlDecode(readFileSync(file, "utf8"));
    for (const pattern of NOT_READY_RUNTIME_CLAIMS) {
      const match = body.match(pattern);
      assert.equal(
        match,
        null,
        `${label} contains an uncaveated runtime crypto claim while runtime-readiness.json is not ready: ${JSON.stringify(match?.[0])}`
      );
    }
  }
}

function runScannerSelfTests() {
  assertNoExternalNetworkBody(
    "safe metadata self-test",
    [
      '<link rel="canonical" href="https://burnbar.ai/trust/">',
      '<meta property="og:image" content="https://burnbar.ai/og/default.png">',
      '<script type="application/ld+json">{"@context":"https://schema.org"}</script>',
      '<a href="https://github.com/Imagine-That-Ai/BurnBar">GitHub</a>',
    ].join("\n")
  );
  for (const [label, body] of [
    ["external script", '<script src="https://cdn.example/app.js"></script>'],
    ["external stylesheet", '<link rel="stylesheet" href="https://fonts.example/style.css">'],
    ["external preload", '<link href="https://fonts.example/font.woff2" rel="preload" as="font">'],
    ["external image", '<img src="https://pixel.example/1x1.gif">'],
    ["external srcset", '<img srcset="/local.png 1x, https://cdn.example/x.png 2x">'],
    ["external iframe", '<iframe src="https://example.com/embed"></iframe>'],
    ["external source", '<source src="https://cdn.example/video.mp4">'],
    ["external form", '<form action="https://collector.example/post"></form>'],
    ["external form action", '<button formaction="https://collector.example/post">Send</button>'],
    ["external ping", '<a href="/local" ping="https://collector.example/ping">A</a>'],
    ["external poster", '<video poster="https://cdn.example/poster.jpg"></video>'],
    ["external meta refresh", '<meta http-equiv="refresh" content="0; url=https://evil.example/">'],
    ["external svg href", '<svg><use xlink:href="https://cdn.example/icon.svg#x"></use></svg>'],
    ["external css import", '@import "https://fonts.example/style.css";'],
    ["external css url", ".hero{background:url(https://cdn.example/bg.png)}"],
    ["external fetch", 'fetch("https://api.example/data")'],
    ["external beacon", 'navigator.sendBeacon("https://analytics.example/hit")'],
    ["xhr token", "new XMLHttpRequest()"],
    ["external websocket", 'new WebSocket("wss://socket.example")'],
    ["external eventsource", 'new EventSource("https://stream.example")'],
    ["dynamic import", 'import("https://cdn.example/mod.mjs")'],
    ["static import", 'import x from "https://cdn.example/mod.mjs"'],
    ["tracker token", "posthog.init('key')"],
  ]) {
    assertBlocked(label, body);
  }
  assertNoDisallowedScriptUrlLiterals("firebaseClient.js", 'fetch("https://identitytoolkit.googleapis.com/v1/accounts")');
  assertNoDisallowedScriptUrlLiterals("firebaseClient.js", "const authUrl = `https://${app.config.authDomain}/__/auth`;");
  assertNoDisallowedScriptUrlLiterals("firebaseClient.js", "const authUrl = `https://${app.authDomain}/__/auth`;");
  assertNoDisallowedScriptUrlLiterals("firebaseClient.js", "const fnUrl = `https://${this.region}-${project}.cloudfunctions.net/callable`;");
  assertNoDisallowedScriptUrlLiterals("firebaseClient.js", "const emulatorUrl = `http://${host}`;");
  assert.throws(
    () => assertNoDisallowedScriptUrlLiterals("feature.js", "const dynamicUrl = `http://${host}`;"),
    /disallowed external URL literal/
  );
  assert.throws(
    () => assertNoDisallowedScriptUrlLiterals("bad.js", 'const sdk = "https://esm.sh/@chenglou/pretext";'),
    /disallowed external URL literal/
  );
  assert.throws(
    () => assertNoWebManifestNetworkBody("external webmanifest icon", '{"icons":[{"src":"https://cdn.example/icon.png"}]}'),
    /external/
  );
}

function parseGeneratedStrings() {
  const generated = readFileSync(TRUST_GENERATED, "utf8");
  const strings = new Set();
  for (const match of generated.matchAll(/"(?:blurb|serverLine|caveat)": ("(?:[^"\\]|\\.)*")/g)) {
    const parsed = JSON.parse(match[1]);
    if (parsed && parsed.length > 24) strings.add(parsed);
  }
  return [...strings];
}

runScannerSelfTests();

for (const route of TRUST_ROUTES) {
  assert.ok(statSync(route).isFile(), `${relative(ROOT, route)} must exist`);
}

const builtFiles = walk(DIST).filter((file) => /\.(?:html|css|js|mjs|svg|xml|webmanifest)$/.test(file));
for (const file of builtFiles) {
  assertNoExternalNetwork(file);
}

const trustHtml = htmlDecode(readFileSync(join(DIST, "trust", "index.html"), "utf8"));
for (const line of parseGeneratedStrings()) {
  assert.ok(trustHtml.includes(line), `/trust does not render generated trust line: ${line}`);
}

assertNoUnreadyRuntimeClaims([...builtFiles, TRUST_GENERATED]);

console.log(`PASS: trust copy scan checked ${builtFiles.length} built HTML/CSS/JS/SVG/XML/manifest files with no disallowed external network refs.`);
