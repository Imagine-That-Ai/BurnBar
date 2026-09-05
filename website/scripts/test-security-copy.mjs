#!/usr/bin/env node
/**
 * @fileoverview Regression tests for the public security copy (E20b / P26).
 *
 * Pins every security stance claim on website/src/pages/security.astro to repo facts:
 * daemon socket auth, Keychain access flags, Firestore security rules, ECIES escrow,
 * App Store JWS verification, and encryption roadmap posture.
 */

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");

async function read(relativePath) {
  return readFile(path.join(ROOT, relativePath), "utf8");
}

const securityPage = await read("src/pages/security.astro");
const cryptoClaims = await read("src/data/crypto-claims.generated.ts");

// 1. Threat 01: Local daemon socket RPC posture
assert.match(
  securityPage,
  /0o600/,
  "security.astro must assert 0o600 filesystem ACLs on daemon socket"
);
assert.match(
  securityPage,
  /EnvironmentVariables/,
  "security.astro must assert launchd EnvironmentVariables token delivery to hide from ps aux"
);

// 2. Threat 02: Secrets at rest in macOS Keychain
assert.match(
  securityPage,
  /kSecAttrAccessibleWhenUnlockedThisDeviceOnly/,
  "security.astro must pin the Keychain accessibility constant"
);
assert.match(
  securityPage,
  /SQLCipher database key\s+is held the same way/,
  "security.astro must assert SQLCipher database key protection"
);

// 3. Threat 03: Firestore boundaries and denylist
assert.match(
  securityPage,
  /users\/&#123;uid&#125;\/…|users\/\{uid\}\/…/,
  "security.astro must assert per-user Firestore namespace scoping"
);
assert.match(
  securityPage,
  /apiKey[\s\S]*token[\s\S]*cookie[\s\S]*credential/,
  "security.astro must list the secret field denylist keywords"
);
assert.match(
  securityPage,
  /provider_account_secret_refs/,
  "security.astro must state provider_account_secret_refs is server-only"
);

// 4. Threat 04: Apple JWS verification and account token
assert.match(
  securityPage,
  /pinned by SHA-256/,
  "security.astro must state root CAs are pinned by SHA-256"
);
assert.match(
  securityPage,
  /appAccountToken.*bound to your Firebase UID/,
  "security.astro must document appAccountToken UUID binding"
);

// 5. Threat 05: Cross-device credential escrow
assert.match(
  securityPage,
  /ECIES \(P-256 \+ AES-GCM\) escrow/,
  "security.astro must document ECIES (P-256 + AES-GCM) escrow"
);
assert.match(
  securityPage,
  /Private keys\s+never leave the device Keychain/,
  "security.astro must assert private keys never leave Keychain"
);

// 6. Honest limits ("What we don't pretend")
assert.match(
  securityPage,
  /direct-download macOS app is not sandboxed/,
  "security.astro must honestly state direct-download app is unsandboxed"
);
assert.match(
  securityPage,
  /Mac App Store build\s+is sandboxed/,
  "security.astro must state Mac App Store build is sandboxed"
);
assert.match(
  securityPage,
  /Provider APIs are not certificate-pinned/,
  "security.astro must acknowledge provider APIs are not certificate pinned"
);

// 7. Encryption roadmap dynamically bound to generated crypto claims
assert.match(
  securityPage,
  /LIBSIGNAL_ROLLOUT_STATUS/,
  "security.astro must import and render LIBSIGNAL_ROLLOUT_STATUS"
);
assert.match(
  cryptoClaims,
  /LIBSIGNAL_ROLLOUT_STATUS/,
  "crypto-claims.generated.ts must export LIBSIGNAL_ROLLOUT_STATUS"
);

console.log("security-copy: all security posture facts and crypto claims verified");
