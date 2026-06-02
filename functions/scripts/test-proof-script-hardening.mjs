#!/usr/bin/env node

import assert from "node:assert/strict";

import { assertHashList } from "./prove-burnbar-pro-cloud-search-live.mjs";
import {
  providerAccountSecretRefID,
  providerAccountSecretRefPath,
  redactPrivateSecretRefPath,
} from "./prove-hosted-quota-live.mjs";

const hash = "a".repeat(32);

assert.doesNotThrow(() => assertHashList(Array.from({ length: 1024 }, () => hash), "tokenHashes", { max: 1024 }));
assert.throws(
  () => assertHashList(Array.from({ length: 1025 }, () => hash), "tokenHashes", { max: 1024 }),
  /bounded hash list/,
);
assert.throws(() => assertHashList(["A".repeat(32)], "tokenHashes", { max: 1024 }), /invalid hash/);

assert.equal(
  providerAccountSecretRefID("uid.with/slash", "codex:hosted/default"),
  "uid-with-slash_codex-hosted-default",
);
assert.equal(
  providerAccountSecretRefPath("uid.with/slash", "codex:hosted/default"),
  "provider_account_secret_refs/uid-with-slash_codex-hosted-default",
);

const redacted = redactPrivateSecretRefPath("uid.with/slash", "codex:hosted/default");
assert.match(redacted, /^provider_account_secret_refs\/sha256_16_[0-9a-f]{16}$/);
assert.doesNotMatch(redacted, /uid|codex|hosted|default/);

console.log("proof script hardening tests passed");
