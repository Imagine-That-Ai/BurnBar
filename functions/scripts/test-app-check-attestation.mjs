#!/usr/bin/env node
import assert from "node:assert/strict";

import {
  APP_CHECK_ATTESTATION_CLAIM_KEY,
  isAppCheckAttestationClaimFresh,
  readAppCheckAttestationClaim,
  readAppIdFromCallableRequest,
} from "../lib/appCheckAttestation.js";

assert.equal(
  readAppIdFromCallableRequest({ app: { appId: "1:999:ios:deadbeef" } }),
  "1:999:ios:deadbeef",
);
assert.equal(readAppIdFromCallableRequest({}), undefined);

const claim = readAppCheckAttestationClaim({
  [APP_CHECK_ATTESTATION_CLAIM_KEY]: {
    v: 1,
    appId: "1:999:ios:deadbeef",
    boundAtMillis: Date.now() - 1_000,
  },
});
assert.ok(claim);
assert.equal(isAppCheckAttestationClaimFresh(claim), true);

console.log("app-check-attestation helper tests passed");
