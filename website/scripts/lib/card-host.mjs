/**
 * card-host.mjs — the Afar Messages card fallback served at `/c/v1` on the
 * existing burnbar.ai marketing origin.
 *
 * A card link is `https://burnbar.ai/c/v1#<fields>`. The fields live in the
 * fragment, which browsers never send, so the server only ever sees `/c/v1`.
 * The page is the canonical bytes from the Afar repository, imported unchanged
 * (`card-host/import-receipt.json`) and served from `public/c/v1.html`, which
 * Astro copies into `dist/` untouched. It carries its own inline script and
 * style, covered by a route-scoped CSP (`card-host/headers.json`, the upstream
 * hosting contract), so its hashes must never reach the site-wide CSP.
 *
 * Everything here is pure and throws `CardHostError` with a specific message,
 * so the build scripts and `test-card-host.mjs` share one definition of
 * "the card fallback" and of a correct hosting config.
 */
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const WEBSITE_ROOT = resolve(fileURLToPath(new URL("../..", import.meta.url)));
export const CARD_ROUTE = "/c/v1";
export const CARD_PUBLIC_FILE = "public/c/v1.html";
export const CARD_DIST_FILE = "dist/c/v1.html";
export const CARD_CONTRACT_FILE = "card-host/headers.json";
export const CARD_RECEIPT_FILE = "card-host/import-receipt.json";

const SOURCE_REPOSITORY = "Ajnunezg/alberto-cloud-mission-control";
const IMPORTED = new Map([
  [CARD_PUBLIC_FILE, "docs/imessage-card-web/c/v1/index.html"],
  [CARD_CONTRACT_FILE, "docs/imessage-card-web/headers.json"]
]);
const GIT_SHA = /^[0-9a-f]{40}$/;
const SHA256_HEX = /^[0-9a-f]{64}$/;
const CSP_SHA = /'sha256-([A-Za-z0-9+/]{43}=)'/g;

/**
 * Headers the route inherits from the site-wide `**` rule without the
 * contract naming them. Each is compatible with a page that loads nothing and
 * already forbids framing. Any other inherited key fails, so a future
 * site-wide header is reviewed against the card before it ships.
 */
const ALLOWED_INHERITED = new Map([
  ["X-Frame-Options", "DENY"],
  ["Cross-Origin-Embedder-Policy", "require-corp"]
]);

export class CardHostError extends Error {
  constructor(message) {
    super(message);
    this.name = "CardHostError";
  }
}

function fail(message) {
  throw new CardHostError(message);
}

export function sha256Hex(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

/** The git blob id of `bytes`, so the receipt can be checked against the source commit. */
export function gitBlobId(bytes) {
  return createHash("sha1").update(`blob ${bytes.length}\0`).update(bytes).digest("hex");
}

/** Escape every RegExp metacharacter, so a literal can never change the pattern. */
function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function cspSource(text) {
  return `'sha256-${createHash("sha256").update(text).digest("base64")}'`;
}

/** Validate the receipt's shape. Returns it; throws on anything unexpected. */
export function validateReceipt(receipt) {
  if (receipt === null || typeof receipt !== "object" || Array.isArray(receipt)) {
    fail("card receipt must be a JSON object");
  }
  if (receipt.schemaVersion !== 1) fail("card receipt schemaVersion must be 1");
  if (receipt.route !== CARD_ROUTE) fail(`card receipt route must be ${CARD_ROUTE}`);
  const source = receipt.source;
  if (source?.repository !== SOURCE_REPOSITORY) {
    fail(`card receipt source.repository must be ${SOURCE_REPOSITORY}`);
  }
  for (const key of ["commit", "tree"]) {
    if (typeof source[key] !== "string" || !GIT_SHA.test(source[key])) {
      fail(`card receipt source.${key} must be a full 40-character lower-case git id`);
    }
  }
  if (!Array.isArray(receipt.files) || receipt.files.length !== IMPORTED.size) {
    fail(`card receipt must list exactly ${IMPORTED.size} files`);
  }
  const seen = new Set();
  for (const entry of receipt.files) {
    const expectedSource = IMPORTED.get(entry?.path);
    if (expectedSource === undefined)
      fail(`card receipt names an unexpected file: ${JSON.stringify(entry?.path)}`);
    if (seen.has(entry.path)) fail(`card receipt lists ${entry.path} twice`);
    seen.add(entry.path);
    if (entry.sourcePath !== expectedSource)
      fail(`${entry.path}: sourcePath must be ${expectedSource}`);
    if (typeof entry.gitBlob !== "string" || !GIT_SHA.test(entry.gitBlob)) {
      fail(`${entry.path}: gitBlob must be a full 40-character lower-case git id`);
    }
    if (typeof entry.sha256 !== "string" || !SHA256_HEX.test(entry.sha256)) {
      fail(`${entry.path}: sha256 must be 64 lower-case hex characters`);
    }
    if (!Number.isSafeInteger(entry.bytes) || entry.bytes <= 0) {
      fail(`${entry.path}: bytes must be a positive integer`);
    }
  }
  return receipt;
}

export function loadReceipt(root = WEBSITE_ROOT) {
  return validateReceipt(JSON.parse(readFileSync(join(root, CARD_RECEIPT_FILE), "utf8")));
}

/** Check one file's bytes against its receipt entry. */
export function verifyImportedBytes(receipt, path, bytes, label = path) {
  const entry = receipt.files.find((file) => file.path === path);
  if (!entry) fail(`card receipt has no entry for ${path}`);
  if (bytes.length !== entry.bytes)
    fail(`${label} is ${bytes.length} bytes; the receipt pins ${entry.bytes}`);
  if (sha256Hex(bytes) !== entry.sha256)
    fail(`${label} does not match its receipt sha256; re-import it unchanged`);
  if (gitBlobId(bytes) !== entry.gitBlob) fail(`${label} does not match its receipt git blob`);
}

/**
 * True for the built card fallback, after proving its bytes are the imported
 * ones. Build scripts use this to leave the page out of site-wide checks; a
 * modified copy throws instead of slipping through the exclusion.
 */
export function isCardFallbackDistFile(file, { root = WEBSITE_ROOT, receipt } = {}) {
  if (resolve(file) !== resolve(root, CARD_DIST_FILE)) return false;
  verifyImportedBytes(
    receipt ?? loadReceipt(root),
    CARD_PUBLIC_FILE,
    readFileSync(file),
    CARD_DIST_FILE
  );
  return true;
}

/** The inline script and style hashes the page needs, in CSP source form. */
export function inlineHashes(html) {
  const blocks = (tag) =>
    [...html.matchAll(new RegExp(`<${tag}\\b[^>]*>([\\s\\S]*?)</${tag}>`, "gi"))].map((m) => m[1]);
  const scripts = blocks("script");
  const styles = blocks("style");
  if (scripts.length !== 1 || styles.length !== 1) {
    fail(
      `the card page must have exactly one inline script and one inline style (found ${scripts.length} and ${styles.length})`
    );
  }
  if (/\sstyle\s*=/i.test(html) || /<script\b[^>]*\bsrc\s*=/i.test(html) || /<link\b/i.test(html)) {
    fail("the card page must not load scripts, styles or other resources, or use style attributes");
  }
  return { script: cspSource(scripts[0]), style: cspSource(styles[0]) };
}

/**
 * Convert a Firebase Hosting `source` glob to a RegExp. Supports the syntax
 * firebase.json uses (`**`, `*`, `?`, `@(a|b)`) and refuses anything else, so
 * an unrecognised pattern can't be misjudged as "does not match".
 */
export function globToRegExp(glob) {
  if (typeof glob !== "string" || glob.length === 0)
    fail("header and redirect sources must be non-empty strings");
  let out = "";
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === "*" && glob[i + 1] === "*") {
      // `**/` also matches nothing, so `**/*.js` covers `/a.js`.
      if (glob[i + 2] === "/") {
        out += "(?:.*/)?";
        i += 2;
      } else {
        out += ".*";
        i += 1;
      }
    } else if (c === "*") out += "[^/]*";
    else if (c === "?") out += "[^/]";
    else if (c === "@" && glob[i + 1] === "(") {
      const close = glob.indexOf(")", i);
      if (close === -1) fail(`unterminated @( ) in source ${glob}`);
      const options = glob.slice(i + 2, close).split("|");
      if (options.some((option) => !/^[A-Za-z0-9._-]+$/.test(option)))
        fail(`unsupported @( ) options in source ${glob}`);
      out += `(?:${options.map(escapeRegExp).join("|")})`;
      i = close;
    } else if (/[A-Za-z0-9/_.-]/.test(c)) out += escapeRegExp(c);
    else fail(`unsupported glob syntax ${JSON.stringify(c)} in source ${glob}`);
  }
  return new RegExp(`^/?${out.replace(/^\//, "")}$`);
}

function matches(rule, path) {
  if (rule.regex !== undefined) return new RegExp(rule.regex).test(path);
  return globToRegExp(rule.source).test(path);
}

/**
 * The headers Firebase Hosting sends for `path`. Duplicate keys resolve
 * last-match-wins (proven against the Hosting emulator by
 * test-card-host-emulator.mjs, and relied on by test-cache-headers.mjs).
 */
export function effectiveHeaders(marketing, path) {
  const out = new Map();
  for (const rule of marketing.headers ?? []) {
    if (!matches(rule, path)) continue;
    for (const { key, value } of rule.headers) out.set(key, value);
  }
  return out;
}

function parsePermissions(value) {
  const denied = new Set();
  for (const part of value.split(",")) {
    const match = /^\s*([a-z-]+)=\(\)\s*$/.exec(part);
    if (match) denied.add(match[1]);
  }
  return denied;
}

function hstsMaxAge(value) {
  const match = /(?:^|;)\s*max-age=(\d+)\s*(?:;|$)/i.exec(value ?? "");
  return match ? Number(match[1]) : -1;
}

/** The route's entry in the upstream hosting contract. */
export function contractRoute(contract) {
  const route = contract?.routes?.[CARD_ROUTE];
  if (!route || route.file !== "c/v1/index.html" || typeof route.headers !== "object") {
    fail(`card-host/headers.json must describe ${CARD_ROUTE} served from c/v1/index.html`);
  }
  return route.headers;
}

/**
 * Validate the marketing hosting config for the card route. Returns the
 * effective headers. Throws on the first violation.
 */
export function validateCardHosting({ marketing, contract, html }) {
  const wanted = contractRoute(contract);
  const hashes = inlineHashes(html);
  const csp = wanted["Content-Security-Policy"];
  const contractHashes = [...csp.matchAll(CSP_SHA)].map((m) => `'sha256-${m[1]}'`);
  if (
    !csp.includes(`script-src ${hashes.script};`) ||
    !csp.includes(`style-src ${hashes.style};`) ||
    contractHashes.length !== 2
  ) {
    fail("the contract CSP does not cover exactly the page's inline script and style");
  }
  const meta = /<meta http-equiv="Content-Security-Policy" content="([^"]+)">/.exec(html)?.[1];
  if (`${meta}; frame-ancestors 'none'` !== csp)
    fail("the page's meta CSP must equal the contract CSP minus frame-ancestors");

  // Routing: /c/v1.html is cleaned to /c/v1 and /c/v1/ loses its slash, both
  // by 301; the exact link /c/v1 is served directly.
  if (marketing.cleanUrls !== true || marketing.trailingSlash !== false) {
    fail("the card route relies on cleanUrls: true and trailingSlash: false");
  }
  for (const path of [CARD_ROUTE, `${CARD_ROUTE}/`, `${CARD_ROUTE}.html`]) {
    for (const rule of marketing.redirects ?? []) {
      if (matches(rule, path)) fail(`redirect ${rule.source ?? rule.regex} must not match ${path}`);
    }
    for (const rule of marketing.rewrites ?? []) {
      if (matches(rule, path)) fail(`rewrite ${rule.source ?? rule.regex} must not match ${path}`);
    }
  }
  if (marketing.i18n !== undefined) fail("i18n rewrites would change how /c/v1 resolves");

  const rules = marketing.headers ?? [];
  const own = rules.filter((rule) => rule.source === CARD_ROUTE);
  if (own.length !== 1) fail(`marketing headers must have exactly one ${CARD_ROUTE} rule`);
  if (rules.indexOf(own[0]) < rules.findIndex((rule) => rule.source === "**")) {
    fail(`the ${CARD_ROUTE} rule must come after "**" so its values win`);
  }

  const effective = effectiveHeaders(marketing, CARD_ROUTE);
  for (const [key, value] of Object.entries(wanted)) {
    const got = effective.get(key);
    if (key === "Content-Type") {
      // Hosting derives it from the .html extension; overriding it is not allowed.
      if (got !== undefined) fail(`${CARD_ROUTE} must not set Content-Type in firebase.json`);
    } else if (key === "Permissions-Policy") {
      const denied = parsePermissions(got ?? "");
      for (const feature of parsePermissions(value)) {
        if (!denied.has(feature)) fail(`${CARD_ROUTE} Permissions-Policy must deny ${feature}`);
      }
    } else if (key === "Strict-Transport-Security") {
      if (hstsMaxAge(got) < hstsMaxAge(value))
        fail(`${CARD_ROUTE} HSTS max-age must be at least the contract's`);
    } else if (got !== value) {
      fail(`${CARD_ROUTE} ${key} must be ${JSON.stringify(value)} (got ${JSON.stringify(got)})`);
    }
  }
  for (const [key, value] of effective) {
    if (key in wanted) continue;
    if (ALLOWED_INHERITED.get(key) !== value) {
      fail(
        `${CARD_ROUTE} inherits ${key}: ${value}, which the card contract does not allow; review it against the card`
      );
    }
  }

  // The card's hashes stay out of every other route's CSP.
  for (const rule of rules) {
    if (rule === own[0]) continue;
    for (const { key, value } of rule.headers) {
      if (
        key === "Content-Security-Policy" &&
        (value.includes(hashes.script) || value.includes(hashes.style))
      ) {
        fail(`the ${rule.source} CSP contains a card hash; the card CSP must stay route-scoped`);
      }
    }
  }
  return effective;
}
