#!/usr/bin/env node
/**
 * CI guard — every NEW callable that reads a client payload must validate it.
 *
 * Firebase `onCall` / `onCallProduction` handlers receive arbitrary
 * client-supplied JSON on `request.data`. A handler that reads that payload
 * without validating it (bounds, shape, allowed values) is the classic
 * injection / abuse surface. This guard scans `functions/src` for callable
 * definitions, flags any that read `request.data` but do not run it through a
 * recognized input validator, and compares that set against a checked-in
 * baseline of pre-existing offenders.
 *
 * The baseline is SHRINK-ONLY:
 *   - A new unvalidated callable that is NOT in the baseline → fail (add
 *     validation — ideally `parseCallableInput` from
 *     `functions/src/validation/callableSchema.ts`).
 *   - A baseline entry that is now validated (or was deleted) → fail asking you
 *     to remove it, so the accepted set can only get smaller over time.
 *
 * A callable is treated as "validated" when its body (or a helper it delegates
 * the payload to) either calls one of the repo's known input validators
 * ({@link INPUT_VALIDATOR_TOKENS}) or throws an inline
 * `HttpsError("invalid-argument", ...)` whose guard or message is tied to the
 * client payload — `request.data`, `req.data`, a destructured `data` alias
 * (`async ({ data }) => …`), or a local derived from one. An inline throw for an
 * unrelated server-side precondition does not count, and a handler that reaches
 * the payload only through destructuring is still flagged. It is intentionally a
 * heuristic — the point is to ratchet the debt down, not to prove correctness.
 *
 * Usage:
 *   node scripts/ci/check-callable-validation.mjs          # check (CI)
 *   node scripts/ci/check-callable-validation.mjs --write   # regenerate baseline
 * Exit: 0 = clean, 1 = drift (new offender or stale baseline entry), 2 = error.
 */

import { promises as fs } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const SRC_DIR = path.join(REPO_ROOT, "functions", "src");
const BASELINE_PATH = path.join(REPO_ROOT, "scripts", "ci", "callable-validation-baseline.json");
const SKIP_DIRS = new Set(["__tests__", "node_modules", "types"]);

/** Recognized input-validation calls. A callable (or helper it delegates to)
 *  using any of these on its payload is treated as validated. Grouped by
 *  source module for maintenance; extend as new validators are introduced. */
export const INPUT_VALIDATOR_TOKENS = [
  // The declarative schema layer (functions/src/validation/callableSchema.ts).
  "parseCallableInput",
  // callables/shared/validators.ts
  "assertProvider",
  "safeIdentifier",
  "requiredIdentifier",
  "boundedTrimmedString",
  "safeCloudDocumentID",
  "requireHexDigest",
  "requireBoundedNumber",
  "requireRecordArray",
  "requireTokenHashes",
  "requireOptionalSearchHashes",
  "requireSealedText",
  "cloudVaultAADContext",
  "optionalISODateString",
  "requireBoundedStringArray",
  "parseProjectMemoryFreshness",
  "requireCloudVaultBlobEnvelope",
  "boundedHttpsURL",
  // callables/shared/storage.ts
  "assertUserStoragePath",
  "assertEncryptedSessionBlobObject",
  // callables/shared/accounts.ts
  "assertHostedProvider",
  "assertSelfHostedProvider",
  // callables/shared/providerConnect.ts
  "normalizeCloudConnectAuthMethodID",
  "normalizeHostedCredential",
  "sanitizeUploadedQuotaSnapshot",
  // Local / cross-cutting payload validators.
  "optionalChoice",
  "boundedAnalyticsDeviceId",
  "requireTrustedDeviceActionProof",
  "enforceHighRiskOwnerAction",
  "parseProvider",
];

const CALLABLE_RE = /export const (\w+)\s*=\s*(onCall|onCallProduction)\b/g;
const READS_INPUT_RE = /\brequest\.data\b|\breq\.data\b/;
const INLINE_INVALID_ARG_RE = /HttpsError\(\s*["']invalid-argument["']/;
// Global variant used to walk every inline `invalid-argument` throw in a body.
const INLINE_INVALID_ARG_GLOBAL = /HttpsError\(\s*["']invalid-argument["']/g;
// Top-level (column-0) function / const definitions. Nested code is indented, so
// a definition's body runs from its line up to the next top-level definition.
const TOP_LEVEL_DEF_RE = /^(?:export\s+)?(?:async\s+)?function\s+(\w+)|^(?:export\s+)?(?:const|let)\s+(\w+)\s*=/gm;

/** Skip a `'…'`, `"…"`, or `` `…` `` literal; return the closing-quote index. */
function skipString(source, openIndex) {
  const quote = source[openIndex];
  for (let i = openIndex + 1; i < source.length; i += 1) {
    const ch = source[i];
    if (ch === "\\") {
      i += 1;
      continue;
    }
    if (ch === quote) return i;
  }
  return source.length - 1;
}

/**
 * Return the index just past the `close` that matches the `open` at `openIndex`,
 * skipping string literals and comments so delimiters inside them do not count.
 */
function matchingDelimiterEnd(source, openIndex, open, close) {
  let depth = 0;
  for (let i = openIndex; i < source.length; i += 1) {
    const ch = source[i];
    const next = source[i + 1];
    if (ch === "/" && next === "/") {
      const nl = source.indexOf("\n", i);
      if (nl === -1) return source.length;
      i = nl;
      continue;
    }
    if (ch === "/" && next === "*") {
      const end = source.indexOf("*/", i + 2);
      if (end === -1) return source.length;
      i = end + 1;
      continue;
    }
    if (ch === '"' || ch === "'" || ch === "`") {
      i = skipString(source, i);
      continue;
    }
    if (ch === open) depth += 1;
    else if (ch === close) {
      depth -= 1;
      if (depth === 0) return i + 1;
    }
  }
  return source.length;
}

export function matchingParenEnd(source, openIndex) {
  return matchingDelimiterEnd(source, openIndex, "(", ")");
}

/** True when `body` calls one of the repo's recognized input-validation helpers. */
function usesValidatorToken(body) {
  return INPUT_VALIDATOR_TOKENS.some((token) => new RegExp(`\\b${token}\\s*\\(`).test(body));
}

/**
 * True when a top-level helper body performs recognized validation — a known
 * validator token or an inline `invalid-argument` throw. Used only to mark
 * *helper* functions as validators so a callable that delegates via
 * `parseFooInput(request.data)` is recognized. Callable bodies themselves use the
 * stricter, payload-tied {@link hasPayloadTiedInvalidArg} check.
 */
function bodyPerformsValidation(body) {
  return INLINE_INVALID_ARG_RE.test(body) || usesValidatorToken(body);
}

/**
 * Names of top-level helpers whose bodies perform input validation, so a
 * callable that delegates via `parseFooInput(request.data)` is recognized. A
 * definition's body spans from its line to the next top-level definition, which
 * sidesteps brace matching around inline object return types
 * (`function f(): { a: string } { … }`).
 */
export function localValidatorNames(source) {
  const defs = [];
  TOP_LEVEL_DEF_RE.lastIndex = 0;
  let m;
  while ((m = TOP_LEVEL_DEF_RE.exec(source)) !== null) {
    defs.push({ name: m[1] ?? m[2], index: m.index });
  }
  const names = new Set();
  for (let i = 0; i < defs.length; i += 1) {
    const region = source.slice(defs[i].index, i + 1 < defs.length ? defs[i + 1].index : source.length);
    if (bodyPerformsValidation(region)) names.add(defs[i].name);
  }
  return names;
}

/** True when `body` calls any of the named local validator helpers. */
function callsLocalValidator(body, localValidators) {
  for (const name of localValidators) {
    if (new RegExp(`\\b${name}\\s*\\(`).test(body)) return true;
  }
  return false;
}

/**
 * Alias(es) bound to the client payload by destructuring the callable handler's
 * request parameter — `async ({ data, auth }) => …` → `"data"`,
 * `async ({ data: payload }) => …` → `"payload"`. A handler that pulls `data` out
 * of the request this way reads client input exactly like `request.data`, so it
 * must face the same validation requirement instead of slipping through as a
 * no-input callable.
 */
export function destructuredDataAliases(body) {
  const aliases = new Set();
  const paramRe = /\(\s*(\{[^{}]*\})\s*(?::[^)]*)?\)\s*=>/g;
  let m;
  while ((m = paramRe.exec(body)) !== null) {
    const dm = /(?:^|[{,])\s*data\s*(?::\s*(\w+))?\s*(?=[,}])/.exec(m[1]);
    if (dm) aliases.add(dm[1] ?? "data");
  }
  return aliases;
}

/** Regex-source matching any payload root: `request.data`, `req.data`, or an alias. */
function payloadRootPattern(aliases) {
  const parts = ["\\brequest\\.data\\b", "\\breq\\.data\\b"];
  for (const alias of aliases) parts.push(`\\b${alias}\\b`);
  return parts.join("|");
}

/** Identifiers bound by a `const/let/var` LHS (plain, object, or array pattern). */
function bindingNames(lhs) {
  const trimmed = lhs.trim();
  if (trimmed.startsWith("{")) {
    return trimmed
      .slice(1, -1)
      .split(",")
      .map((part) => {
        const seg = part.includes(":") ? part.slice(part.indexOf(":") + 1) : part;
        const name = /(\w+)/.exec(seg);
        return name ? name[1] : null;
      })
      .filter((n) => n !== null);
  }
  if (trimmed.startsWith("[")) return [...trimmed.matchAll(/(\w+)/g)].map((x) => x[1]);
  const name = /(\w+)/.exec(trimmed);
  return name ? [name[1]] : [];
}

// RHS is captured up to the statement's end of line (not the next `;`) so the
// enclosing `const NAME = onCall(… => {` wrapper — which has no `;` until deep
// inside the handler — does not swallow the first inner payload extraction.
const ASSIGNMENT_RE = /\b(?:const|let|var)\s+(\{[^{}]*\}|\[[^\]]*\]|\w+)\s*(?::[^=;\n]+)?=\s*([^;\n]+)/g;

/**
 * Local variables whose value derives (transitively) from a payload root — e.g.
 * `const scope = request.data.scope` or `const parsed = parseFoo(request.data)`.
 * Computed to a fixpoint so a value pulled through several intermediate locals
 * still counts as payload-derived, letting a hand-rolled guard that checks a
 * local copy of the payload count as validating the payload.
 */
function payloadDerivedLocals(body, rootPattern) {
  const derived = new Set();
  let changed = true;
  while (changed) {
    changed = false;
    const refRe = new RegExp([rootPattern, ...[...derived].map((d) => `\\b${d}\\b`)].join("|"));
    ASSIGNMENT_RE.lastIndex = 0;
    let m;
    while ((m = ASSIGNMENT_RE.exec(body)) !== null) {
      if (!refRe.test(m[2])) continue;
      for (const name of bindingNames(m[1])) {
        if (!derived.has(name)) {
          derived.add(name);
          changed = true;
        }
      }
    }
  }
  return derived;
}

/** If the `{` at `braceIndex` opens an `if (...)` body, return its condition text. */
function ifConditionBefore(source, braceIndex) {
  let i = braceIndex - 1;
  while (i >= 0 && /\s/.test(source[i])) i -= 1;
  if (source[i] !== ")") return null;
  let depth = 0;
  let open = -1;
  for (let j = i; j >= 0; j -= 1) {
    if (source[j] === ")") depth += 1;
    else if (source[j] === "(") {
      depth -= 1;
      if (depth === 0) {
        open = j;
        break;
      }
    }
  }
  if (open === -1) return null;
  let k = open - 1;
  while (k >= 0 && /\s/.test(source[k])) k -= 1;
  // Preceding token must be the keyword `if` (and not an identifier ending in …if).
  if (k >= 1 && source[k] === "f" && source[k - 1] === "i" && (k - 2 < 0 || !/[A-Za-z0-9_$]/.test(source[k - 2]))) {
    return source.slice(open + 1, i);
  }
  return null;
}

/** Condition text of the innermost `if (...)` block enclosing `throwIndex`, or "". */
function enclosingIfCondition(source, throwIndex) {
  let depth = 0;
  for (let i = throwIndex - 1; i >= 0; i -= 1) {
    if (source[i] === "}") depth += 1;
    else if (source[i] === "{") {
      if (depth === 0) return ifConditionBefore(source, i) ?? "";
      depth -= 1;
    }
  }
  return "";
}

/**
 * Guard controlling the inline throw at `throwIndex`: the enclosing `if (...)`
 * condition plus the throw's own statement prefix (which captures a brace-less
 * `if (cond) throw …`). Used to decide whether an `invalid-argument` throw is
 * gated on a check of the payload rather than an unrelated precondition.
 */
export function controllingGuard(source, throwIndex) {
  let depth = 0;
  let start = -1;
  for (let i = throwIndex - 1; i >= 0; i -= 1) {
    const ch = source[i];
    if (ch === ")" || ch === "}" || ch === "]") depth += 1;
    else if (ch === "(" || ch === "{" || ch === "[") {
      if (depth === 0) {
        start = i;
        break;
      }
      depth -= 1;
    } else if (ch === ";" && depth === 0) {
      start = i;
      break;
    }
  }
  const prefix = source.slice(start + 1, throwIndex);
  return `${enclosingIfCondition(source, throwIndex)} ${prefix}`;
}

/**
 * True when a callable `body` contains an inline `HttpsError("invalid-argument")`
 * throw actually tied to the payload — its controlling guard or its message
 * references a payload root (`request.data` / `req.data` / a destructured alias)
 * or a local derived from one. Replaces the old "any inline invalid-argument
 * counts" shortcut so a throw for an unrelated server-side precondition can no
 * longer mask an unvalidated `request.data.foo` read.
 */
export function hasPayloadTiedInvalidArg(body, aliases = new Set()) {
  const rootPattern = payloadRootPattern(aliases);
  const derived = payloadDerivedLocals(body, rootPattern);
  const refRe = new RegExp([rootPattern, ...[...derived].map((d) => `\\b${d}\\b`)].join("|"));
  INLINE_INVALID_ARG_GLOBAL.lastIndex = 0;
  let m;
  while ((m = INLINE_INVALID_ARG_GLOBAL.exec(body)) !== null) {
    const open = body.indexOf("(", m.index);
    const message = open === -1 ? "" : body.slice(open, matchingParenEnd(body, open));
    const context = `${controllingGuard(body, m.index)} ${message}`;
    if (refRe.test(context)) return true;
  }
  return false;
}

/**
 * Analyze one source file's callables.
 * @param globalValidators names of validating helpers defined anywhere in the
 *   tree, so a callable that delegates to a cross-file `parseFooInput(...)` (as
 *   stripe.ts does) is recognized just like a same-file helper.
 * @returns array of { name, key, line, readsInput, validated }.
 */
export function analyzeSource(relFile, source, globalValidators = new Set()) {
  const validators = new Set(localValidatorNames(source));
  for (const name of globalValidators) validators.add(name);
  const results = [];
  CALLABLE_RE.lastIndex = 0;
  let match;
  while ((match = CALLABLE_RE.exec(source)) !== null) {
    const name = match[1];
    const openParen = source.indexOf("(", match.index + match[0].length - 1);
    const bodyEnd = openParen === -1 ? source.length : matchingParenEnd(source, openParen);
    const body = source.slice(match.index, bodyEnd);
    const line = source.slice(0, match.index).split("\n").length;
    const aliases = destructuredDataAliases(body);
    results.push({
      name,
      key: `${relFile}::${name}`,
      line,
      readsInput: READS_INPUT_RE.test(body) || aliases.size > 0,
      validated:
        usesValidatorToken(body) ||
        callsLocalValidator(body, validators) ||
        hasPayloadTiedInvalidArg(body, aliases),
    });
  }
  return results;
}

async function walk(dir) {
  const out = [];
  let entries;
  try {
    entries = await fs.readdir(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (SKIP_DIRS.has(entry.name)) continue;
      out.push(...(await walk(full)));
    } else if (entry.isFile() && full.endsWith(".ts") && !full.endsWith(".d.ts")) {
      out.push(full);
    }
  }
  return out;
}

/** Scan the tree and return offenders (callables that read input unvalidated). */
export async function computeUnvalidatedCallables() {
  const files = (await walk(SRC_DIR)).sort();
  // Pass 1: read every file once and union its validating helper names so
  // cross-file delegation (e.g. stripe.ts → stripeInputSchemas.ts) is resolved.
  const sources = new Map();
  const globalValidators = new Set();
  for (const file of files) {
    const source = await fs.readFile(file, "utf8");
    sources.set(file, source);
    for (const name of localValidatorNames(source)) globalValidators.add(name);
  }
  // Pass 2: classify each callable against the global validator set.
  const offenders = [];
  for (const file of files) {
    const rel = path.relative(REPO_ROOT, file);
    for (const callable of analyzeSource(rel, sources.get(file), globalValidators)) {
      if (callable.readsInput && !callable.validated) {
        offenders.push({ ...callable, file: rel });
      }
    }
  }
  offenders.sort((a, b) => a.key.localeCompare(b.key));
  return offenders;
}

/** Compare current offender keys with the baseline (shrink-only ratchet). */
export function diffBaseline(currentKeys, baselineKeys) {
  const current = new Set(currentKeys);
  const baseline = new Set(baselineKeys);
  const added = currentKeys.filter((k) => !baseline.has(k));
  const stale = baselineKeys.filter((k) => !current.has(k));
  return { added, stale };
}

async function readBaseline() {
  try {
    const raw = await fs.readFile(BASELINE_PATH, "utf8");
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed.unvalidatedCallables) ? parsed.unvalidatedCallables : [];
  } catch {
    return [];
  }
}

async function writeBaseline(keys) {
  const body = {
    _comment:
      "SHRINK-ONLY baseline for scripts/ci/check-callable-validation.mjs. Each entry is a " +
      "pre-existing callable that reads request.data without a recognized input validator. " +
      "Do not add entries; add validation (parseCallableInput from " +
      "functions/src/validation/callableSchema.ts) and remove the entry instead. Regenerate " +
      "with: node scripts/ci/check-callable-validation.mjs --write",
    unvalidatedCallables: [...keys].sort((a, b) => a.localeCompare(b)),
  };
  await fs.writeFile(BASELINE_PATH, `${JSON.stringify(body, null, 2)}\n`);
}

async function main() {
  const write = process.argv.includes("--write");
  const offenders = await computeUnvalidatedCallables();
  const currentKeys = offenders.map((o) => o.key);

  if (write) {
    await writeBaseline(currentKeys);
    console.log(`✓ Wrote ${currentKeys.length} baselined callable(s) to ${path.relative(REPO_ROOT, BASELINE_PATH)}.`);
    return;
  }

  const baselineKeys = await readBaseline();
  const { added, stale } = diffBaseline(currentKeys, baselineKeys);

  if (added.length === 0 && stale.length === 0) {
    console.log(`✓ Callable input-validation guard clean (${currentKeys.length} baselined offender(s)).`);
    return;
  }

  if (added.length > 0) {
    const byKey = new Map(offenders.map((o) => [o.key, o]));
    console.error("✖ New callable(s) read request.data without a recognized input validator:\n");
    for (const key of added) {
      const o = byKey.get(key);
      console.error(`  ${o.file}:${o.line}  ${o.name}`);
    }
    console.error(
      "\nValidate the payload with parseCallableInput() from " +
        "functions/src/validation/callableSchema.ts (preferred) or an existing shared/validators.ts helper.\n" +
        "If the handler genuinely takes no client input, this is a false positive — refactor so it does not " +
        "reference request.data, or (discouraged, requires review) baseline it with --write.",
    );
  }

  if (stale.length > 0) {
    console.error("\n✖ Stale baseline entr(ies) — now validated or removed (baseline is shrink-only):\n");
    for (const key of stale) console.error(`  ${key}`);
    console.error("\nDelete these from scripts/ci/callable-validation-baseline.json (or run --write).");
  }

  process.exit(1);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((err) => {
    console.error("check-callable-validation failed:", err);
    process.exit(2);
  });
}
