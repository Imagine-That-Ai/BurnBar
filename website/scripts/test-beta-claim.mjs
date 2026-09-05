#!/usr/bin/env node
/**
 * Static source contract for the /beta free-Ultra claim flow.
 *
 * The claim page grants a paid tier, so it runs the same attestation sequence
 * as /link (bind App Check -> refresh ID token -> mint high-risk nonce ->
 * callable) and must never invoke the callable for a signed-out visitor or a
 * code that cannot be real. It also has a one-click `?code=` path, which needs
 * a latch so a failed auto-claim cannot loop through the visitor's rate limit.
 *
 * The success copy is checked here too: an account that already pays for Ultra
 * must not be told its code was applied.
 */
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const repoRoot = path.resolve(root, "..");
const read = (base, relativePath) => readFile(path.join(base, relativePath), "utf8");

const [beta, campaigns] = await Promise.all([
  read(root, "src/pages/beta.astro"),
  read(repoRoot, "config/promo-campaigns.json")
]);

// Prettier reflows prose across lines, so copy assertions run against a
// whitespace-collapsed view. Structural assertions keep using the raw source.
const betaProse = beta.replace(/\s+/gu, " ");

// --- Claim runs through the attested callable helper ---
assert.match(
  beta,
  /import \{\s*attestedCallable,\s*callableErrorCode,\s*isAppCheckBindingConflictError\s*\} from "\.\.\/lib\/attestedCallable";/,
  "beta.astro must use the attested callable helper and its exported error helpers"
);
assert.match(
  beta,
  /attestedCallable<\{ status\?: string \}>\(\s*"redeemPromoCode",\s*\{\s*code\s*\}\)/,
  "claim must call redeemPromoCode through the attested helper"
);
assert.doesNotMatch(
  beta,
  /httpsCallable\(/,
  "beta.astro must not bypass the attestation helper with a raw callable"
);

// --- Signed-out visitors never invoke the callable ---
const claimBody = beta.slice(beta.indexOf("async function claim()"));
assert.match(
  claimBody,
  /if \(!currentUser\) \{[\s\S]*?showState\("signedOut"\)[\s\S]*?return;/,
  "claim must return signed-out visitors to the sign-in state"
);
assert.ok(
  claimBody.indexOf('attestedCallable<{ status?: string }>("redeemPromoCode"') >
    claimBody.indexOf("if (!currentUser)"),
  "the session guard must precede the attested callable invocation"
);

// --- Codes that cannot be real are rejected before spending a request ---
assert.match(
  claimBody,
  /if \(code\.replace\(\/\[\^A-Za-z0-9\]\/g, ""\)\.length < 4\) \{[\s\S]*?return;/,
  "a code below the server's canonicalization floor must return before the callable"
);
assert.match(claimBody, /setAttribute\("aria-invalid", "true"\)/, "an unusable code must set aria-invalid");

// --- One-click ?code= claims once per load ---
assert.match(beta, /params\.get\("code"\)/, "the code field must be prefilled from ?code=");
assert.match(beta, /let autoClaimUsed = false;/, "the one-click path must carry a latch");
assert.match(
  beta,
  /if \(queryCode && !autoClaimUsed\) \{\s*autoClaimUsed = true;\s*void claim\(\);/,
  "the auto-claim must set its latch before claiming so a failure cannot loop"
);

// --- Sign-in offers Google and Apple, and promises no payment ---
assert.match(beta, /id="btn-signin"/, "signed-out state must offer Google sign-in");
assert.match(beta, /Sign in with Google/, "Google button must be labeled");
assert.match(beta, /id="btn-signin-apple"/, "signed-out state must offer Apple sign-in");
assert.match(beta, /Sign in with Apple/, "Apple button must be labeled");
assert.match(betaProse, /No payment method required\./, "the claim page must state that no payment method is needed");

// --- Success copy is honest about which outcome occurred ---
assert.match(
  beta,
  /result\?\.status === "already_entitled"/,
  "an existing paid subscriber must be branched separately from a fresh grant"
);
assert.match(
  betaProse,
  /This account already has an active Ultra subscription/,
  "a paying subscriber must not be told their code was applied"
);
assert.match(
  beta,
  /result\?\.status === "already_redeemed"/,
  "a repeat claim must be branched separately from a fresh grant"
);
assert.match(
  betaProse,
  /You were not charged, and there is nothing to cancel\./,
  "the granted state must say plainly that nothing was charged"
);

// --- Distinct operator copy per failure, never raw server text for the common cases ---
assert.match(
  beta,
  /errorCode === "not-found" \|\| errorCode === "invalid-argument"/,
  "an unusable code must map to the re-enter-code branch"
);
assert.match(
  betaProse,
  /That code isn't valid\. Check the code from the announcement and try again\./,
  "unusable codes must show the curated re-enter copy"
);
assert.match(
  betaProse,
  /Every pass in this beta has been claimed\./,
  "an exhausted campaign must have its own copy, distinct from a rate limit"
);
assert.match(
  betaProse,
  /Too many attempts from this account\./,
  "a rate limit must have its own copy, distinct from an exhausted campaign"
);
assert.match(
  beta,
  /isAppCheckBindingConflictError\(\s*err\s*\)/,
  "binding-mismatch failures must be recognized via the exported helper"
);
assert.match(
  betaProse,
  /Your device attestation could not be verified for this action\. Sign in again and retry\./,
  "attestation failures must show attestation retry copy"
);
assert.match(beta, /isUnauthenticated/, "platform Unauthenticated must be mapped explicitly");

// --- The page never renders a live code or entitlement internals ---
const successState = beta.slice(beta.indexOf('id="state-success"'), beta.indexOf("</section>"));
assert.doesNotMatch(
  successState,
  /accessToken|refreshToken|Bearer|burnbar_ultra|entitlement/i,
  "the success state must never display tokens or entitlement internals"
);

// --- The placeholder matches a campaign that actually exists in config ---
const definedCodes = JSON.parse(campaigns).campaigns.map((entry) => entry.defaultCode);
const placeholder = /placeholder="([^"]+)"/u.exec(beta)?.[1];
assert.ok(
  definedCodes.includes(placeholder),
  `the code placeholder ${placeholder} must name a campaign defined in config/promo-campaigns.json`
);

// --- Retry returns the visitor to the right state ---
assert.match(
  beta,
  /if \(currentUser\) \{[\s\S]*?showState\("claim"\)[\s\S]*?\} else \{[\s\S]*?showState\("signedOut"\)/,
  "retry must return signed-in users to the claim state and signed-out users to sign-in"
);

console.log("beta-claim: attested /beta claim flow source contract passed");
