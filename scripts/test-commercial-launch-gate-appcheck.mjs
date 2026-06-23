#!/usr/bin/env node
/**
 * Unit test for commercial-launch-gate Firebase App Check enforcement probe logic.
 */

import assert from "node:assert/strict";
import {
  REQUIRED_FIREBASE_APP_CHECK_SERVICE_IDS,
  buildFirebaseAppCheckCurlConfig,
  evaluateFirebaseAppCheckEnforcement,
  evaluateFirebaseAppCheckServiceSet,
  firebaseAppCheckCurlArgs,
} from "./commercial-launch-gate.mjs";

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
  const failedServiceIds = missingStorage.services
    .filter((service) => !service.ok)
    .map((service) => service.serviceId);
  assert.deepEqual(
    failedServiceIds,
    ["firebasestorage.googleapis.com"],
  );
}

{
  const malformedProbe = evaluateFirebaseAppCheckServiceSet(null);
  assert.equal(malformedProbe.ok, false);
  const failedServiceIds = malformedProbe.services
    .filter((service) => !service.ok)
    .map((service) => service.serviceId);
  assert.deepEqual(
    failedServiceIds,
    REQUIRED_FIREBASE_APP_CHECK_SERVICE_IDS,
  );
}

{
  const config = buildFirebaseAppCheckCurlConfig(
    "projects/123/services/firestore.googleapis.com",
    "ya29.test-access-token",
    {
      userProject: "burnbar-test",
    },
  );
  assert.match(config, /retry = 2/u);
  assert.match(config, /retry-all-errors/u);
  assert.match(config, /connect-timeout = 15/u);
  assert.match(config, /max-time = 45/u);
  assert.match(config, /header = "Authorization: Bearer ya29\.test-access-token"/u);
  assert.match(config, /header = "x-goog-user-project: burnbar-test"/u);
  assert.match(
    config,
    /url = "https:\/\/firebaseappcheck\.googleapis\.com\/v1beta\/projects\/123\/services\/firestore\.googleapis\.com"/u,
  );
  assert.deepEqual(firebaseAppCheckCurlArgs("/tmp/private-curl.conf"), [
    "--config",
    "/tmp/private-curl.conf",
  ]);
  assert.doesNotMatch(
    JSON.stringify(firebaseAppCheckCurlArgs("/tmp/private-curl.conf")),
    /ya29\.test-access-token/u,
  );
}

console.log("commercial-launch-gate App Check probe tests passed");
