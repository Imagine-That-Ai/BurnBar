#!/usr/bin/env node
/**
 * test-security-copy.mjs — /security says only what the repository can prove.
 *
 * A security page is the one page where repeating yesterday's sentence is a
 * lie rather than staleness. This gate therefore reads three things: the page
 * source, the BUILT page (so an interpolation that stops rendering is caught
 * where a reader would see it), and the implementation files that decide
 * whether each claim is still true.
 *
 * Eight invariants:
 *
 *   1. The daemon socket's mode is computed from the `chmod(…)` call in
 *      `BurnBarUnixDomainSocket.swift` — the S_I* symbols folded into an octal
 *      — and the page must print that exact octal. Widen the socket to the
 *      group and the page's `0o600` fails.
 *   2. The Keychain accessibility class is read out of
 *      `DatabaseEncryptionService.swift`; every `kSecAttrAccessible` site must
 *      agree, and the page must name the constant they agree on.
 *   3. Firestore's per-user namespace rule is still uid equality, and the
 *      user-namespace matches are still guarded by it.
 *   4. `provider_account_secret_refs` still has no client `match` block at
 *      all — which is what "server-only" means in Firestore — so publishing a
 *      client read rule for it fails the page's claim.
 *   5. Every denylisted field name the page prints is actually denied by
 *      `hasNoPlaintextSecretFields()` in `firestore.rules`.
 *   6. The remaining threat-model and honest-limit claims still stand on the
 *      built page (JWS pinning, appAccountToken binding, ECIES escrow, the
 *      unsandboxed direct download, the un-pinned provider APIs).
 *   7. `LIBSIGNAL_ROLLOUT_STATUS` is RENDERED: the built page carries the
 *      generated string, and the source still interpolates the constant rather
 *      than hard-coding its current value. Replace the interpolation with
 *      prose and this fails even though the import survives.
 *   8. The gateway-visibility disclosure survives — the sentence saying the
 *      seal is opened at the gateway to run the model, so it protects the path
 *      and not the prompt from us. That is the page's server-blindness
 *      boundary; without it the privacy claim reads far stronger than it is.
 */

import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");
const REPO = join(ROOT, "..");
const PAGE = join(ROOT, "dist", "security", "index.html");

assert.ok(existsSync(PAGE), `expected a built /security page at ${PAGE} — run astro build first`);

const securityPage = readFileSync(join(ROOT, "src", "pages", "security.astro"), "utf8");
const cryptoClaims = readFileSync(join(ROOT, "src", "data", "crypto-claims.generated.ts"), "utf8");
const html = readFileSync(PAGE, "utf8");

const socketSource = readFileSync(
  join(REPO, "OpenBurnBarDaemon", "Sources", "OpenBurnBarDaemon", "BurnBarUnixDomainSocket.swift"),
  "utf8"
);
const encryptionSource = readFileSync(
  join(REPO, "AgentLens", "Services", "DataStore", "DatabaseEncryptionService.swift"),
  "utf8"
);
const firestoreRules = readFileSync(join(REPO, "firestore.rules"), "utf8");

/* One pass, chained so `&amp;lt;` never double-decodes (CodeQL). */
const ENTITIES = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  "#39": "'",
  "#123": "{",
  "#125": "}",
  "#8203": ""
};
const decodeEntities = (s) =>
  s.replace(/&(amp|lt|gt|quot|#39|#123|#125|#8203);/g, (_, name) => ENTITIES[name]);
const text = decodeEntities(html.replace(/<[^>]+>/g, " "))
  .replace(/\s+/g, " ")
  .trim();

const collapse = (s) => s.replace(/\s+/g, " ");
const rulesFlat = collapse(firestoreRules);

const failures = [];
const check = (ok, message) => {
  if (!ok) failures.push(message);
};

/* ── 1 · socket mode, computed from the chmod call ──────────────────────── */

const MODE_BITS = {
  S_IRUSR: 0o400,
  S_IWUSR: 0o200,
  S_IXUSR: 0o100,
  S_IRGRP: 0o040,
  S_IWGRP: 0o020,
  S_IXGRP: 0o010,
  S_IROTH: 0o004,
  S_IWOTH: 0o002,
  S_IXOTH: 0o001
};

const restrictAt = socketSource.indexOf("static func restrictSocketPermissions(");
assert.notEqual(
  restrictAt,
  -1,
  "restrictSocketPermissions is gone from BurnBarUnixDomainSocket.swift — /security's socket-ACL claim has no implementation to point at"
);
const chmodCall = collapse(socketSource.slice(restrictAt, restrictAt + 400)).match(
  /chmod\(socketPath, ([^)]+)\)/
);
assert.ok(chmodCall, "could not read the chmod(…) mode in restrictSocketPermissions");

let socketMode = 0;
for (const rawToken of chmodCall[1].split("|")) {
  const token = rawToken.trim();
  const octal = /^0o([0-7]{1,4})$/.exec(token);
  if (octal) {
    socketMode |= parseInt(octal[1], 8);
    continue;
  }
  assert.ok(
    Object.hasOwn(MODE_BITS, token),
    `unrecognised permission token ${JSON.stringify(token)} in restrictSocketPermissions — teach this gate about it before shipping`
  );
  socketMode |= MODE_BITS[token];
}
const socketOctal = `0o${socketMode.toString(8).padStart(3, "0")}`;

const pageSocketMode = text.match(/filesystem ACLs set to (0o[0-7]+)/)?.[1];
check(
  pageSocketMode === socketOctal,
  `the built /security page says the daemon socket is ${pageSocketMode ?? "(claim missing)"} but restrictSocketPermissions chmods it to ${socketOctal}`
);
check(
  /The plist itself is\s+<code>0o600<\/code>/.test(securityPage),
  "security.astro must keep the launchd plist permission claim"
);
check(
  /EnvironmentVariables/.test(text),
  "the built /security page must state the auth token is delivered via launchd EnvironmentVariables, keeping it out of ps aux"
);

/* ── 2 · Keychain accessibility, read from the encryption service ───────── */

const accessibilityConstants = new Set(
  [...encryptionSource.matchAll(/kSecAttrAccessible as String:\s*(kSecAttrAccessible\w+)/g)].map(
    (m) => m[1]
  )
);
assert.ok(
  accessibilityConstants.size > 0,
  "no kSecAttrAccessible attribute found in DatabaseEncryptionService.swift — /security's Keychain claim has no implementation to point at"
);
check(
  accessibilityConstants.size === 1,
  `DatabaseEncryptionService.swift stores Keychain items under more than one accessibility class (${[
    ...accessibilityConstants
  ].join(", ")}) — /security claims a single one`
);

const [accessibility] = accessibilityConstants;
check(
  text.includes(accessibility),
  `the built /security page must name the Keychain accessibility constant the code actually uses (${accessibility})`
);
check(
  /SQLCipher database key\s+is held the same way/.test(securityPage),
  "security.astro must assert the SQLCipher database key gets the same Keychain protection"
);

/* ── 3 · Firestore per-user namespace scoping ───────────────────────────── */

check(
  rulesFlat.includes(
    "function ownsUserNamespace(userId) { return isSignedIn() && request.auth.uid == userId; }"
  ),
  "firestore.rules no longer scopes ownsUserNamespace to uid equality — /security claims owner-scoped rules per users/{uid}/…"
);
check(
  /match \/users\/\{userId\} \{ allow read: if ownsUserNamespace\(userId\);/.test(rulesFlat),
  "the users/{uid} root document is no longer read-guarded by ownsUserNamespace"
);
check(
  /match \/users\/\{userId\}\/\{collectionId\}\/\{documentId\} \{ allow read: if ownsUserNamespace\(userId\)/.test(
    rulesFlat
  ),
  "the users/{uid}/… collection sweep is no longer read-guarded by ownsUserNamespace"
);
check(
  text.includes("owner-scoped rules per users/{uid}/…"),
  "the built /security page must assert per-user Firestore namespace scoping"
);

/* ── 4 · provider_account_secret_refs stays server-only ─────────────────── */

const clientMatchedPaths = [...firestoreRules.matchAll(/^\s*match\s+(\S+)\s*\{/gm)].map(
  (m) => m[1]
);
assert.ok(
  clientMatchedPaths.length > 20,
  `parsed only ${clientMatchedPaths.length} match blocks out of firestore.rules — parser is wrong`
);
const secretRefMatches = clientMatchedPaths.filter((p) =>
  p.includes("provider_account_secret_refs")
);
check(
  secretRefMatches.length === 0,
  `firestore.rules now publishes client rules for provider_account_secret_refs (${secretRefMatches.join(", ")}) — /security says it is server-only, all client reads denied`
);
check(
  text.includes("provider_account_secret_refs is server-only"),
  "the built /security page must state provider_account_secret_refs is server-only"
);

/* ── 5 · the denylist the page prints is the denylist the rules enforce ─── */

const denylistFn = firestoreRules.match(
  /function hasNoPlaintextSecretFields\(\)\s*\{([\s\S]*?)\n\s*\}/
);
assert.ok(denylistFn, "could not find hasNoPlaintextSecretFields() in firestore.rules");
const deniedFields = new Set(
  [...denylistFn[1].matchAll(/!\("([A-Za-z]+)" in d\)/g)].map((m) => m[1])
);
assert.ok(deniedFields.size > 3, `parsed ${deniedFields.size} denied fields — parser is wrong`);

const denylistCopy = securityPage.match(
  /secret-field-name denylist \(([\s\S]*?)\), and Firebase App Check/
);
assert.ok(denylistCopy, "could not find the denylist sentence in security.astro");
const advertisedFields = [...denylistCopy[1].matchAll(/<code>([A-Za-z]+)<\/code/g)].map(
  (m) => m[1]
);
check(
  advertisedFields.length >= 4,
  `the denylist sentence names only ${advertisedFields.length} field(s) — it should print a representative handful`
);
for (const field of advertisedFields) {
  check(
    deniedFields.has(field),
    `/security advertises "${field}" as a denylisted Firestore field, but hasNoPlaintextSecretFields() no longer rejects it`
  );
}

/* ── 6 · the remaining threat-model and honest-limit claims ─────────────── */

const RENDERED_CLAIMS = [
  ["pinned by SHA-256", "root CAs are pinned by SHA-256"],
  ["ECIES (P-256 + AES-GCM) escrow", "ECIES escrow for cross-device credentials"],
  ["direct-download macOS app is not sandboxed", "the unsandboxed direct download"],
  ["Provider APIs are not certificate-pinned", "provider APIs are not certificate pinned"]
];
for (const [needle, why] of RENDERED_CLAIMS) {
  check(text.includes(needle), `the built /security page must carry the claim about ${why}`);
}
check(
  /appAccountToken.*bound to your Firebase UID/.test(securityPage),
  "security.astro must document the appAccountToken UUID binding"
);
check(
  /Private keys\s+never leave the device Keychain/.test(securityPage),
  "security.astro must assert private keys never leave the Keychain"
);
check(
  /Mac App Store build\s+is sandboxed/.test(securityPage),
  "security.astro must state the Mac App Store build is sandboxed"
);

/* ── 7 · the rollout status is rendered, not just imported ──────────────── */

const rolloutStatus = cryptoClaims.match(/export const LIBSIGNAL_ROLLOUT_STATUS = "([^"]+)";/)?.[1];
assert.ok(
  rolloutStatus,
  "crypto-claims.generated.ts must export LIBSIGNAL_ROLLOUT_STATUS — run `npm run crypto-claims:generate`"
);
check(
  securityPage.includes("{LIBSIGNAL_ROLLOUT_STATUS}"),
  "security.astro must interpolate {LIBSIGNAL_ROLLOUT_STATUS} rather than describing the rollout in prose"
);
check(
  !securityPage.includes(rolloutStatus),
  `security.astro hard-codes the current rollout status ("${rolloutStatus}") instead of leaving it to the generated constant`
);
check(
  text.includes(`Today it is ${rolloutStatus} —`),
  `the built /security page must render the generated rollout status ("Today it is ${rolloutStatus} —"); the import alone proves nothing reached the reader`
);

/* ── 8 · the gateway-visibility disclosure ──────────────────────────────── */

const DISCLOSURE = [
  "at the gateway that seal is opened to run the model",
  "it protects the path, not the prompt from us"
];
for (const clause of DISCLOSURE) {
  check(
    text.includes(clause),
    `the built /security page must keep the gateway-visibility disclosure (${JSON.stringify(clause)}) — without it the encrypted-seal paragraph reads as server-blindness we do not have`
  );
}

/* ── report ─────────────────────────────────────────────────────────────── */

if (failures.length > 0) {
  console.error(`security-copy: ${failures.length} claim(s) no longer match the repository:\n`);
  for (const failure of failures) console.error(`  ✗ ${failure}`);
  console.error("");
  process.exit(1);
}

console.log(
  `security-copy: socket ${socketOctal}, Keychain ${accessibility}, ${deniedFields.size} denylisted Firestore fields, rollout status "${rolloutStatus}" rendered, and the gateway-visibility disclosure verified`
);
