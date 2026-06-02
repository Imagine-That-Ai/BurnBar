#!/usr/bin/env node
/**
 * Pure regression tests for the live paid-tier proof command.
 */

import assert from "node:assert/strict";
import {
  assertGooglePlayAuditRecord,
  assertPaidTierEntitlement,
  parseArgs,
  selfTest,
} from "./prove-paid-tier-live.mjs";

const future = new Date(Date.now() + 86_400_000).toISOString();
const past = new Date(Date.now() - 86_400_000).toISOString();

assert.equal(selfTest().ok, true);
assert.deepEqual(parseArgs(["--self-test"]).selfTest, true);
assert.equal(parseArgs(["--uid", "u1", "--tier", "cloud-pro", "--channel", "stripe"]).requireAllowanceLedger, true);
assert.equal(parseArgs(["--uid", "u1", "--tier", "cloud", "--channel", "apple"]).requireAllowanceLedger, false);
assert.equal(
  parseArgs([
    "--uid",
    "u1",
    "--tier",
    "cloud-pro",
    "--channel",
    "google_play",
    "--purchase-token-hash",
    "hash_123",
    "--google-play-audit-record",
  ]).googlePlayAuditRecord,
  true,
);
assert.throws(
  () =>
    parseArgs([
      "--uid",
      "u1",
      "--tier",
      "cloud-pro",
      "--channel",
      "stripe",
      "--purchase-token-hash",
      "hash_123",
      "--google-play-audit-record",
    ]),
  /requires --channel google_play/,
);
assert.throws(
  () =>
    parseArgs(["--uid", "u1", "--tier", "cloud-pro", "--channel", "google_play", "--google-play-audit-record"]),
  /requires --purchase-token-hash/,
);

{
  const proof = assertPaidTierEntitlement(
    {
      id: "burnbar_pro",
      active: true,
      productID: "com.openburnbar.pro.monthly",
      source: "apple_jws_verified",
      environment: "Production",
      expiresAt: future,
      features: {
        hostedQuota: true,
        hostedLLM: true,
        encryptedSessionLogBackup: true,
        cloudConversationSearch: true,
      },
    },
    { tier: "cloud", channel: "apple", environment: "Production", allowSandbox: false },
  );
  assert.equal(proof.productID, "com.openburnbar.pro.monthly");
}

{
  const proof = assertPaidTierEntitlement(
    {
      id: "burnbar_pro_max",
      active: true,
      productID: "com.openburnbar.proMax.annual",
      source: "stripe_webhook_verified",
      environment: "Production",
      expiresAt: future,
      externalSubscriptionID: "sub_123",
      features: {
        hostedQuota: true,
        hostedLLM: true,
        encryptedSessionLogBackup: true,
        cloudConversationSearch: true,
        floo: true,
        agentControl: true,
      },
    },
    {
      tier: "cloud-pro",
      channel: "stripe",
      environment: "Production",
      allowSandbox: false,
      externalSubscriptionID: "sub_123",
    },
  );
  assert.equal(proof.externalSubscriptionIDHash.length, 64);
}

{
  const proof = assertPaidTierEntitlement(
    {
      id: "burnbar_pro_max",
      active: true,
      productID: "com.openburnbar.promax.v2.monthly",
      source: "google_play_verified",
      environment: "Production",
      expiresAt: future,
      features: {
        hostedQuota: true,
        hostedLLM: true,
        encryptedSessionLogBackup: true,
        cloudConversationSearch: true,
        floo: true,
        agentControl: true,
      },
    },
    { tier: "cloud-pro", channel: "google_play", environment: "Production", allowSandbox: false },
  );
  assert.equal(proof.productID, "com.openburnbar.promax.v2.monthly");
}

{
  const proof = assertGooglePlayAuditRecord(
    {
      productID: "com.openburnbar.promax.v2.monthly",
      lineItemProductID: "com.openburnbar.promax.v2.monthly",
      entitlementID: "burnbar_pro_max",
      purchaseTokenHash: "token_hash",
      subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
      expiresAt: future,
    },
    {
      tier: "cloud-pro",
      channel: "google_play",
      productID: "",
      purchaseTokenHash: "token_hash",
    },
  );
  assert.equal(proof.productID, "com.openburnbar.promax.v2.monthly");
}

assert.throws(
  () =>
    assertPaidTierEntitlement(
      {
        id: "burnbar_pro",
        active: true,
        productID: "com.openburnbar.pro.monthly",
        source: "apple_jws_verified",
        environment: "Production",
        expiresAt: future,
        features: {
          hostedQuota: true,
          hostedLLM: true,
          encryptedSessionLogBackup: true,
          cloudConversationSearch: true,
          floo: true,
        },
      },
      { tier: "cloud", channel: "apple", environment: "Production", allowSandbox: false },
    ),
  /must not be true/,
);

assert.throws(
  () =>
    assertPaidTierEntitlement(
      {
        id: "burnbar_pro",
        active: true,
        productID: "com.openburnbar.pro.monthly",
        source: "stripe_webhook_verified",
        environment: "Production",
        expiresAt: future,
        features: {
          hostedQuota: true,
          hostedLLM: true,
          encryptedSessionLogBackup: true,
          cloudConversationSearch: true,
        },
      },
      { tier: "cloud", channel: "apple", environment: "Production", allowSandbox: false },
    ),
  /source does not match channel/,
);

assert.throws(
  () =>
    assertPaidTierEntitlement(
      {
        id: "burnbar_pro_max",
        active: true,
        productID: "com.openburnbar.pro.monthly",
        source: "google_play_verified",
        environment: "Production",
        expiresAt: future,
        features: {
          hostedQuota: true,
          hostedLLM: true,
          encryptedSessionLogBackup: true,
          cloudConversationSearch: true,
          floo: true,
          agentControl: true,
        },
      },
      { tier: "cloud-pro", channel: "google_play", environment: "Production", allowSandbox: false },
    ),
  /productID is not valid/,
);

assert.throws(
  () =>
    assertPaidTierEntitlement(
      {
        id: "burnbar_pro",
        active: true,
        productID: "com.openburnbar.pro.monthly",
        source: "apple_jws_verified",
        environment: "Production",
        expiresAt: past,
        features: {
          hostedQuota: true,
          hostedLLM: true,
          encryptedSessionLogBackup: true,
          cloudConversationSearch: true,
        },
      },
      { tier: "cloud", channel: "apple", environment: "Production", allowSandbox: false },
    ),
  /expired/,
);

assert.throws(
  () =>
    assertGooglePlayAuditRecord(
      {
        productID: "com.openburnbar.promax.v2.monthly",
        entitlementID: "burnbar_pro_max",
        purchaseTokenHash: "token_hash",
        subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
        expiresAt: past,
      },
      {
        tier: "cloud-pro",
        channel: "google_play",
        productID: "",
        purchaseTokenHash: "token_hash",
      },
    ),
  /expired/,
);

console.log("prove-paid-tier-live tests passed");
