/**
 * Fail-closed proof for the ops-alert notification-channel gate.
 *
 * Cure53 RR-4: an audited email notification channel pointing at an NXDOMAIN /
 * unresolvable domain stays `enabled` in GCP but never verifies, yet the old
 * gate counted it as live (present && enabled) so the policy read green. These
 * tests pin the stricter contract: a verifiable channel (email/sms) only counts
 * when verificationStatus === "VERIFIED", placeholder/unresolvable targets are
 * rejected outright, and unknown types or empty targets fail closed.
 *
 * Run: node --test scripts/lib/ops-alerts-gate.test.mjs
 */

import test from "node:test";
import assert from "node:assert/strict";

import {
  channelTarget,
  isPlaceholderTarget,
  evaluateChannel,
  VERIFIABLE_CHANNEL_TYPES,
  ALLOWED_CHANNEL_TYPES,
} from "./ops-alerts-gate.mjs";

// Mirrors the per-channel status object built in checkAlertPolicies: the fields
// evaluateChannel consumes, with `target` already resolved via channelTarget.
function status(overrides = {}) {
  return {
    name: "projects/burnbar/notificationChannels/1",
    present: true,
    enabled: true,
    type: "email",
    displayName: "Ops email",
    verificationStatus: "VERIFIED",
    target: "ops@burnbar.ai",
    ...overrides,
  };
}

test("channelTarget reads the type-specific label and trims it", () => {
  assert.equal(
    channelTarget({ type: "email", labels: { email_address: "  ops@burnbar.ai  " } }),
    "ops@burnbar.ai",
  );
  assert.equal(channelTarget({ type: "sms", labels: { number: "+15551234567" } }), "+15551234567");
  assert.equal(channelTarget({ type: "pubsub", labels: { topic: "projects/p/topics/t" } }), "projects/p/topics/t");
  assert.equal(channelTarget({ type: "email", labels: { email_address: "" } }), null);
  assert.equal(channelTarget({ type: "email", labels: {} }), null);
  assert.equal(channelTarget(null), null);
});

test("isPlaceholderTarget flags empty and known unresolvable/placeholder targets", () => {
  assert.equal(isPlaceholderTarget(null), true);
  assert.equal(isPlaceholderTarget(""), true);
  assert.equal(isPlaceholderTarget("ops@example.com"), true);
  assert.equal(isPlaceholderTarget("ops@example.org"), true);
  assert.equal(isPlaceholderTarget("alerts@nxdomain.invalid"), true);
  assert.equal(isPlaceholderTarget("root@localhost"), true);
  assert.equal(isPlaceholderTarget("changeme@burnbar.ai"), true);
  // A real routable address must pass.
  assert.equal(isPlaceholderTarget("ops@burnbar.ai"), false);
  assert.equal(isPlaceholderTarget("+15551234567"), false);
});

test("evaluateChannel passes a verified email channel with a real target", () => {
  assert.deepEqual(evaluateChannel(status()), { ok: true, reason: null });
});

test("evaluateChannel FAILS CLOSED on an enabled-but-UNVERIFIED email channel (RR-4 NXDOMAIN case)", () => {
  // The audited channel: enabled in GCP, real-looking domain, but verification
  // never completes because the MX/domain does not resolve.
  const result = evaluateChannel(status({ verificationStatus: "UNVERIFIED" }));
  assert.equal(result.ok, false, "an unverified email channel must NOT count as live");
  assert.equal(result.reason, "unverified:UNVERIFIED");
});

test("evaluateChannel fails closed when verificationStatus is missing/unspecified", () => {
  assert.equal(evaluateChannel(status({ verificationStatus: null })).ok, false);
  assert.equal(
    evaluateChannel(status({ verificationStatus: "VERIFICATION_STATUS_UNSPECIFIED" })).reason,
    "unverified:VERIFICATION_STATUS_UNSPECIFIED",
  );
});

test("evaluateChannel rejects a placeholder target even when GCP reports VERIFIED", () => {
  const result = evaluateChannel(status({ target: "ops@example.com", verificationStatus: "VERIFIED" }));
  assert.equal(result.ok, false);
  assert.equal(result.reason, "placeholder-target:ops@example.com");
});

test("evaluateChannel fails closed on missing, disabled, and empty-target channels", () => {
  assert.equal(evaluateChannel(status({ present: false })).reason, "missing");
  assert.equal(evaluateChannel(status({ enabled: false })).reason, "disabled");
  assert.equal(evaluateChannel(status({ target: null })).reason, "empty-target");
});

test("evaluateChannel rejects unknown channel types", () => {
  const result = evaluateChannel(status({ type: "carrierpigeon", target: "coop-7" }));
  assert.equal(result.ok, false);
  assert.equal(result.reason, "unsupported-type:carrierpigeon");
  assert.equal(evaluateChannel(status({ type: null })).reason, "unsupported-type:null");
});

test("evaluateChannel does not demand verification for non-verifiable allowed types", () => {
  // pubsub/slack/webhook carry no GCP verification handshake — a present,
  // enabled, real-target channel of these types counts as live.
  assert.deepEqual(
    evaluateChannel(status({ type: "pubsub", target: "projects/burnbar/topics/ops", verificationStatus: null })),
    { ok: true, reason: null },
  );
  assert.equal(
    evaluateChannel(status({ type: "slack", target: "#ops-alerts", verificationStatus: "UNVERIFIED" })).ok,
    true,
  );
});

test("verifiable types are a subset of allowed types", () => {
  for (const type of VERIFIABLE_CHANNEL_TYPES) {
    assert.ok(ALLOWED_CHANNEL_TYPES.has(type), `${type} must also be an allowed channel type`);
  }
});
