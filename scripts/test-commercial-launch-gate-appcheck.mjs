#!/usr/bin/env node
/**
 * Unit test for commercial-launch-gate Firebase App Check enforcement probe logic.
 */

import assert from "node:assert/strict";
import {
  REQUIRED_FIREBASE_APP_CHECK_SERVICE_IDS,
  evaluateFirebaseAppCheckEnforcement,
  evaluateFirebaseAppCheckServiceSet,
} from "./lib/evaluate-firebase-app-check-enforcement.mjs";

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
  const storage = evaluateFirebaseAppCheckEnforcement({
    serviceName: "projects/123/services/firebasestorage.googleapis.com",
    enforcementMode: "ENFORCED",
  });
  assert.equal(storage.ok, true);
  assert.equal(storage.enforcementMode, "ENFORCED");
}

{
  const misconfigured = evaluateFirebaseAppCheckEnforcement({
    serviceName: "projects/123/services/firestore.googleapis.com",
    enforcementMode: "UNENFORCED",
  });
  assert.equal(misconfigured.ok, false);
  assert.match(String(misconfigured.error), /ENFORCED/);
}

{
  const serviceSet = evaluateFirebaseAppCheckServiceSet([
    {
      serviceId: "firestore.googleapis.com",
      serviceName: "projects/123/services/firestore.googleapis.com",
      enforcementMode: "ENFORCED",
    },
    {
      serviceId: "firebasestorage.googleapis.com",
      serviceName: "projects/123/services/firebasestorage.googleapis.com",
      enforcementMode: "ENFORCED",
    },
  ]);
  assert.equal(serviceSet.ok, true);
  assert.deepEqual(
    serviceSet.requiredServiceIds,
    REQUIRED_FIREBASE_APP_CHECK_SERVICE_IDS,
  );
  assert.equal(serviceSet.services.length, 2);
}

{
  const missingStorage = evaluateFirebaseAppCheckServiceSet([
    {
      serviceId: "firestore.googleapis.com",
      serviceName: "projects/123/services/firestore.googleapis.com",
      enforcementMode: "ENFORCED",
    },
  ]);
  assert.equal(missingStorage.ok, false);
  assert.ok(String(missingStorage.error).includes("firebasestorage.googleapis.com"));
}

{
  const malformedProbe = evaluateFirebaseAppCheckServiceSet(null);
  assert.equal(malformedProbe.ok, false);
  assert.ok(String(malformedProbe.error).includes("firestore.googleapis.com"));
  assert.ok(String(malformedProbe.error).includes("firebasestorage.googleapis.com"));
}

console.log("commercial-launch-gate App Check probe tests passed");
