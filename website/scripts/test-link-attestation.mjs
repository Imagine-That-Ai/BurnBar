#!/usr/bin/env node
/**
 * Static source contract for the /link App Check attestation flow.
 *
 * Mirrors the Mac client sequence (ComputerUseSecurityCallableClient):
 *   bindAppCheckAttestation -> getIdToken(true) -> issueHighRiskActionNonce
 *   -> completeCliLink({ userCode, nonce })
 * with one rebound/remint when the nonce mint hits an App Check binding
 * conflict. The callable argument keeps the hyphenated Firestore display
 * value (XXXX-XXXX); the hyphen is stripped only for the 8-char length gate.
 */
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = (relativePath) => readFile(path.join(root, relativePath), "utf8");

const [link, helper] = await Promise.all([
  read("src/pages/link.astro"),
  read("src/lib/attestedCallable.ts")
]);

// --- Attested helper: bind -> getIdToken(true) -> nonce -> target with nonce ---
assert.match(
  helper,
  /bindAppCheckAttestation/,
  "helper must bind the App Check attestation before high-risk actions"
);
assert.match(
  helper,
  /getIdToken\(true\)/,
  "helper must force-refresh the ID token so the obb_app_check claims propagate"
);
assert.match(helper, /issueHighRiskActionNonce/, "helper must mint a high-risk action nonce");
assert.match(
  helper,
  /\{\s*\.\.\.payload,\s*nonce\s*\}/,
  "target callable must receive { ...payload, nonce }"
);
assert.match(
  helper,
  /reboundHighRiskActionNonce/,
  "helper must include the rebound path for App Check binding conflicts"
);
assert.match(
  helper,
  /isAppCheckBindingConflictError/,
  "rebound must only fire for App Check binding conflict errors"
);
assert.match(
  helper,
  /async function reboundHighRiskActionNonce[\s\S]*?bindAppCheckAttestation\(\)[\s\S]*?issueHighRiskActionNonce\(\)/,
  "rebound must re-run bind -> refresh -> remint before retrying"
);

// --- link.astro uses the helper for completeCliLink ---
assert.match(
  link,
  /import \{\s*attestedCallable,\s*callableErrorCode,\s*isAppCheckBindingConflictError\s*\} from "\.\.\/lib\/attestedCallable";/,
  "link.astro must use the attested callable helper and its exported error helpers"
);
assert.match(
  link,
  /attestedCallable\(\s*"completeCliLink",\s*\{\s*userCode:\s*displayCode\s*\}\)/,
  "confirm must call completeCliLink through the helper"
);
assert.match(
  link,
  /const displayCode = \(codeInput\?\.value \|\| ""\)\.trim\(\);/,
  "userCode must be the trimmed display value"
);
assert.match(
  link,
  /const stripped = displayCode\.replace\(\/-\/g, ""\);/,
  "the hyphen must be stripped only for the length gate, never for the payload"
);

// --- Error normalization reuses the helper export (no duplicated functions/ prefix stripping) ---
assert.match(
  link,
  /callableErrorCode\(\s*err\s*\)/,
  "link.astro must normalize error codes through the exported callableErrorCode"
);
assert.match(
  link,
  /isAppCheckBindingConflictError\(\s*err\s*\)/,
  "link.astro must reuse the exported binding-conflict recognizer"
);
assert.doesNotMatch(
  link.slice(link.indexOf("catch (err: unknown)")),
  /replace\(\/\^functions\//,
  "link.astro must not duplicate functions/ prefix stripping"
);

// --- Relative order of the attestation sequence (whitespace tolerant): bind -> getIdToken(true) -> issueHighRiskActionNonce -> completeCliLink ---
// The bind / refresh / nonce steps live in the attested helper; the target
// callable invocation lives in link.astro, so the order is asserted across
// both files concatenated.
const sequence =
  /bindAppCheckAttestation[\s\S]*?getIdToken\(\s*true\s*\)[\s\S]*?issueHighRiskActionNonce[\s\S]*?completeCliLink/;
assert.match(
  `${helper}\n${link}`,
  sequence,
  "the flow must show bind -> getIdToken(true) -> issueHighRiskActionNonce -> completeCliLink in order"
);

// --- Incomplete codes never reach the callable ---
assert.match(
  link,
  /if \(stripped\.length !== 8\) \{[\s\S]*?codeHint\?\.classList\.remove\("hidden"\)[\s\S]*?return;/,
  "incomplete codes must show the hint and return before any callable invocation"
);
assert.match(
  link,
  /codeInput\?\.setAttribute\("aria-invalid", "true"\)/,
  "incomplete codes must set aria-invalid"
);

// --- Signed-out visitors cannot invoke completeCliLink ---
const confirmHandler = link.slice(link.indexOf("btnConfirm?.addEventListener"));
assert.match(
  confirmHandler,
  /if \(!currentUser\) \{[\s\S]*?showState\("signedOut"\)[\s\S]*?return;/,
  "confirm must return signed-out visitors to the sign-in state"
);
assert.ok(
  confirmHandler.indexOf('attestedCallable("completeCliLink"') >
    confirmHandler.indexOf("if (!currentUser)"),
  "the session guard must precede the attested callable invocation"
);

// --- Distinct operator copy: not-found / expired ---
assert.match(
  link,
  /Link session not found or code expired\. Please ensure you entered the exact code from your terminal\./,
  "not-found/expired must show the re-enter-code copy"
);

// --- Distinct operator copy: expired-code failed-precondition (curated, not raw server text) ---
assert.match(
  link,
  /errorCode === "not-found"\s*\|\|\s*\(isFailedPrecondition\s*&&\s*\/expired\/i\.test\(errorText\)\)/,
  "expired-code failed-precondition must join the curated not-found/expired branch"
);
assert.match(
  link,
  /Link session not found or code expired\. Please ensure you entered the exact code from your terminal\./,
  "expired-code failed-precondition must show the curated expired copy, not the raw server string"
);

// --- Distinct operator copy: Pro entitlement (discriminator, not any failed-precondition) ---
assert.match(
  link,
  /isPermissionDenied && \/Pro is required\/\.test\(errorText\)/,
  "Pro copy must be selected by the entitlement message, not by any failed-precondition"
);
assert.match(
  link,
  /BurnBar Pro is required for Remote MCP access\. Please subscribe to continue\./,
  "Pro copy must name Remote MCP and subscribing"
);

// --- Distinct operator copy: bind/nonce failed-precondition (not the Pro string) ---
assert.match(
  link,
  /isFailedPrecondition\s*&&\s*\/nonce\|bindAppCheckAttestation\|App Check\|attestation\/i\.test\(errorText\)/,
  "bind/nonce failed-precondition must keep its own branch"
);
assert.match(
  link,
  /Your device attestation could not be verified for this action\. Sign in again and retry/,
  "bind/nonce copy must be attestation/retry copy, distinct from the Pro string"
);

// --- Distinct operator copy: App Check binding-mismatch permission-denied (attestation retry, not the Pro string) ---
assert.match(
  link,
  /isAppCheckBindingConflictError\(\s*err\s*\)/,
  "binding-mismatch permission-denied must be recognized via the exported binding-conflict helper"
);
assert.match(
  link,
  /Your device attestation could not be verified for this action\. Sign in again and retry/,
  "binding mismatch must reuse the attestation retry copy, never the Pro string"
);

// --- Distinct operator copy: platform Unauthenticated (not the Pro string) ---
assert.match(link, /isUnauthenticated/, "platform Unauthenticated must be mapped explicitly");
assert.match(
  link,
  /Your sign-in could not be verified\. Sign in again and try once more\./,
  "Unauthenticated must show attestation/sign-in copy, not the Pro string"
);

// --- Signed-out state offers Google and Apple sign-in ---
assert.match(link, /id="btn-signin"/, "signed-out state must offer Google sign-in");
assert.match(link, /Sign in with Google/, "Google button must be labeled");
assert.match(link, /id="btn-signin-apple"/, "signed-out state must offer Apple sign-in");
assert.match(link, /Sign in with Apple/, "Apple button must be labeled");

// --- Signed-in state: account badge, code field with ?code= prefill, confirm control ---
assert.match(link, /id="user-badge"/, "signed-in state must show the account badge");
assert.match(link, /id="code-input"/, "signed-in state must show the link-code field");
assert.match(link, /params\.get\("code"\)/, "the code field must be prefilled from ?code=");
assert.match(link, /Link this terminal/, "signed-in state must offer the confirm control");

// --- Success state is secret-free ---
assert.match(link, /id="state-success"/, "success state must exist");
assert.match(link, /CLI linked/, "success state must say CLI linked");
assert.doesNotMatch(
  link.slice(link.indexOf('id="state-success"'), link.indexOf("</section>")),
  /accessToken|refreshToken|Bearer|grant/,
  "success state must never display tokens or grant JSON"
);

// --- Retry returns the operator to the right state ---
assert.match(
  link,
  /if \(currentUser\) \{[\s\S]*?showState\("confirm"\)[\s\S]*?\} else \{[\s\S]*?showState\("signedOut"\)/,
  "retry must return signed-in users to confirm and signed-out users to sign-in"
);

console.log("link-attestation: attested /link flow source contract passed");
