#!/usr/bin/env node
/**
 * Unit test for commercial-launch-gate Firestore App Check enforcement probe logic.
 */

import assert from "node:assert/strict";
import { evaluateFirebaseAppCheckEnforcement } from "./lib/evaluate-firebase-app-check-enforcement.mjs";

{
  const enforced = evaluateFirebaseAppCheckEnforcement({
    serviceName: "projects/123/services/firestore.googleapis.com",
    enforcementMode: "ENFORCED",
    updateTime: "2026-05-30T00:00:00Z",
  });
  assert.equal(enforced.ok, true);
  assert.equal(enforced.enforcementMode, "ENFORCED");
}

{
  const misconfigured = evaluateFirebaseAppCheckEnforcement({
    serviceName: "projects/123/services/firestore.googleapis.com",
    enforcementMode: "UNENFORCED",
  });
  assert.equal(misconfigured.ok, false);
  assert.match(String(misconfigured.error), /ENFORCED/);
}

console.log("commercial-launch-gate App Check probe tests passed");
