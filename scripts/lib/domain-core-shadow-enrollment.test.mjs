import assert from "node:assert/strict";
import test from "node:test";
import {
  clearDomainCoreShadowClaims,
  enrollmentMatches,
  mergeDomainCoreShadowClaims,
  normalizeDomainCoreShadowEnrollment,
} from "./domain-core-shadow-enrollment.mjs";

test("normalizes a unique sorted consumer enrollment", () => {
  assert.deepEqual(normalizeDomainCoreShadowEnrollment("internal", ["windows", "apple", "windows"]), {
    channel: "internal",
    consumers: ["apple", "windows"],
  });
});

test("merge and clear preserve unrelated custom claims", () => {
  const enrollment = normalizeDomainCoreShadowEnrollment("beta", ["apple"]);
  const merged = mergeDomainCoreShadowClaims({ paid: true }, enrollment);
  assert.deepEqual(merged, { paid: true, domainCoreShadowChannel: "beta", domainCoreShadowConsumers: ["apple"] });
  assert.deepEqual(clearDomainCoreShadowClaims(merged), { paid: true });
});

test("verification requires exact channel and consumer set", () => {
  const enrollment = normalizeDomainCoreShadowEnrollment("internal", ["apple", "windows"]);
  assert.equal(enrollmentMatches(mergeDomainCoreShadowClaims({}, enrollment), enrollment), true);
  assert.equal(enrollmentMatches({ domainCoreShadowChannel: "internal", domainCoreShadowConsumers: ["apple"] }, enrollment), false);
});

test("unknown channels and consumers are rejected", () => {
  assert.throws(() => normalizeDomainCoreShadowEnrollment("production", ["apple"]), /channel/);
  assert.throws(() => normalizeDomainCoreShadowEnrollment("internal", ["mystery"]), /consumers/);
});
