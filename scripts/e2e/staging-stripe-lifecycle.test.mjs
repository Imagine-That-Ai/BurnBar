#!/usr/bin/env node

import assert from "node:assert/strict";
import { closeSync, fstatSync, mkdtempSync, openSync, readFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  assertExactDeployment,
  buildLifecycleEvidence,
  executeStagingStripeLifecycle,
  STAGING_STRIPE_LIFECYCLE_SCHEMA,
  verifyLifecycleEvidence,
  writeLifecycleEvidence,
} from "./staging-stripe-lifecycle-core.mjs";

const CHECKOUT_ID = "cs_test_exact_lifecycle";
const CUSTOMER_ID = "cus_exact_lifecycle";
const SUBSCRIPTION_ID = "sub_exact_lifecycle";
const PAYMENT_METHOD_ID = "pm_exact_lifecycle";
const CHARGE_ID = "ch_exact_lifecycle";
const REFUND_ID = "re_exact_lifecycle";
const CHECKOUT_EVENT_ID = "evt_checkout_exact";
const CANCEL_EVENT_ID = "evt_cancel_scheduled_exact";
const REFUND_EVENT_ID = "evt_refund_exact";
const SUBSCRIPTION_DELETED_EVENT_ID = "evt_subscription_deleted_exact";
const CUSTOMER_DELETED_EVENT_ID = "evt_customer_deleted_exact";
const CANDIDATE_SHA = "a".repeat(40);
const CANDIDATE_TREE = "b".repeat(40);

function event(id, type, object) {
  return {
    id,
    type,
    data: { object },
  };
}

function successfulFixture(overrides = {}) {
  const calls = [];
  const events = new Map([
    [
      "checkout.session.completed",
      event(CHECKOUT_EVENT_ID, "checkout.session.completed", {
        id: CHECKOUT_ID,
      }),
    ],
    [
      "customer.subscription.updated",
      event(CANCEL_EVENT_ID, "customer.subscription.updated", {
        id: SUBSCRIPTION_ID,
        status: "active",
        cancel_at_period_end: true,
      }),
    ],
    [
      "charge.refunded",
      event(REFUND_EVENT_ID, "charge.refunded", {
        id: CHARGE_ID,
      }),
    ],
    [
      "customer.subscription.deleted",
      event(SUBSCRIPTION_DELETED_EVENT_ID, "customer.subscription.deleted", {
        id: SUBSCRIPTION_ID,
        status: "canceled",
      }),
    ],
    [
      "customer.deleted",
      event(CUSTOMER_DELETED_EVENT_ID, "customer.deleted", {
        id: CUSTOMER_ID,
        deleted: true,
      }),
    ],
  ]);
  const entitlements = [
    {
      active: true,
      platform: "stripe",
      externalSubscriptionID: SUBSCRIPTION_ID,
      externalCustomerID: CUSTOMER_ID,
      rawStatus: "active",
      sourceEventID: CHECKOUT_EVENT_ID,
    },
    {
      active: true,
      platform: "stripe",
      externalSubscriptionID: SUBSCRIPTION_ID,
      externalCustomerID: CUSTOMER_ID,
      rawStatus: "active",
      sourceEventID: CANCEL_EVENT_ID,
    },
    {
      active: false,
      platform: "stripe",
      externalSubscriptionID: SUBSCRIPTION_ID,
      externalCustomerID: CUSTOMER_ID,
      rawStatus: "active:payment_reversed",
      sourceEventID: REFUND_EVENT_ID,
    },
    {
      active: false,
      platform: "stripe",
      externalSubscriptionID: SUBSCRIPTION_ID,
      externalCustomerID: CUSTOMER_ID,
      rawStatus: "canceled",
      sourceEventID: SUBSCRIPTION_DELETED_EVENT_ID,
    },
  ];
  let entitlementIndex = 0;

  const adapter = {
    getStripeAccount: async () => {
      calls.push("account");
      return { id: "acct_1REg6cCFamvUJU7y" };
    },
    createCheckout: async () => {
      calls.push("checkout:create");
      return {
        sessionId: CHECKOUT_ID,
        url: "https://checkout.stripe.com/c/pay/test",
      };
    },
    getCheckoutSession: async () => {
      calls.push("checkout:open");
      return {
        id: CHECKOUT_ID,
        status: "open",
        mode: "subscription",
        livemode: false,
        amount_total: 799,
        currency: "usd",
        customer: CUSTOMER_ID,
        metadata: {
          entitlementID: "burnbar_pro",
          tier: "cloud",
          cadence: "monthly",
        },
      };
    },
    createPaymentMethod: async () => {
      calls.push("payment-method:create");
      return { id: PAYMENT_METHOD_ID };
    },
    confirmCheckout: async () => {
      calls.push("checkout:confirm");
      return { ok: true };
    },
    waitForCompletedCheckout: async () => {
      calls.push("checkout:complete");
      return {
        id: CHECKOUT_ID,
        status: "complete",
        payment_status: "paid",
        subscription: SUBSCRIPTION_ID,
      };
    },
    findStripeEvent: async ({ type, predicate = () => true }) => {
      calls.push(`event:${type}`);
      const matchingEvent = events.get(type);
      return predicate(matchingEvent) ? matchingEvent : undefined;
    },
    waitForWebhookLedger: async (eventID) => {
      calls.push(`ledger:${eventID}`);
      return { eventID, status: "processed" };
    },
    waitForEntitlement: async (expectedActive) => {
      const currentIndex = entitlementIndex;
      const entitlement = entitlements[entitlementIndex];
      entitlementIndex += 1;
      calls.push(`entitlement:${expectedActive}:${currentIndex}`);
      return entitlement;
    },
    createPortalSession: async () => {
      calls.push("portal:create");
      return { url: "https://billing.stripe.com/p/session/test" };
    },
    scheduleCancellation: async () => {
      calls.push("cancellation:schedule");
      return {
        id: SUBSCRIPTION_ID,
        status: "active",
        cancel_at_period_end: true,
      };
    },
    findPaidCharge: async () => {
      calls.push("charge:find");
      return { id: CHARGE_ID, paid: true, refunded: false };
    },
    createRefund: async () => {
      calls.push("refund:create");
      return { id: REFUND_ID };
    },
    waitForPaymentReversal: async () => {
      calls.push("reversal:wait");
      return {
        reversed: true,
        reason: "fully_refunded",
        subscriptionID: SUBSCRIPTION_ID,
        chargeID: CHARGE_ID,
      };
    },
    deleteSubscription: async () => {
      calls.push("subscription:delete");
      return { id: SUBSCRIPTION_ID, status: "canceled" };
    },
    deleteCustomer: async () => {
      calls.push("customer:delete");
      return { id: CUSTOMER_ID, deleted: true };
    },
  };
  return {
    adapter: Object.assign(adapter, overrides.adapter),
    calls,
    entitlements,
    events,
  };
}

function successfulProof() {
  return {
    checkout: {
      sessionID: CHECKOUT_ID,
      eventID: CHECKOUT_EVENT_ID,
      amountCents: 799,
      currency: "usd",
      paymentStatus: "paid",
    },
    subscription: {
      subscriptionID: SUBSCRIPTION_ID,
      customerID: CUSTOMER_ID,
      entitlementID: "burnbar_pro",
    },
    cancellation: {
      scheduled: true,
      cancelAtPeriodEnd: true,
      status: "active",
      eventID: CANCEL_EVENT_ID,
      entitlementRemainedActive: true,
    },
    refund: {
      chargeID: CHARGE_ID,
      refundID: REFUND_ID,
      eventID: REFUND_EVENT_ID,
      reversalReason: "fully_refunded",
      entitlementRawStatus: "active:payment_reversed",
    },
    cleanup: {
      subscriptionDeletedEventID: SUBSCRIPTION_DELETED_EVENT_ID,
      customerDeletedEventID: CUSTOMER_DELETED_EVENT_ID,
      completed: true,
    },
    billingPortal: {
      sessionCreated: true,
    },
  };
}

function deployments(sourceCommit = CANDIDATE_SHA) {
  return [
    "createStripeBurnBarProCheckoutSession",
    "createStripeBurnBarProPortalSession",
    "stripeBurnBarProWebhook",
  ].map((name, index) => ({
    name,
    state: "ACTIVE",
    revision: `${name.toLowerCase()}-0000${index + 1}-abc`,
    sourceCommit,
    functionVersion: `staging-${sourceCommit}`,
  }));
}

test("runs cancellation-first, proves paid-through access, then reverses payment before cleanup", async () => {
  const fixture = successfulFixture();
  const proof = await executeStagingStripeLifecycle(fixture.adapter);

  assert.equal(proof.cancellation.cancelAtPeriodEnd, true);
  assert.equal(proof.cancellation.entitlementRemainedActive, true);
  assert.equal(proof.refund.entitlementRawStatus, "active:payment_reversed");
  assert.equal(proof.refund.reversalReason, "fully_refunded");

  const scheduleIndex = fixture.calls.indexOf("cancellation:schedule");
  const cancellationLedgerIndex = fixture.calls.indexOf(
    `ledger:${CANCEL_EVENT_ID}`,
  );
  const paidThroughEntitlementIndex =
    fixture.calls.indexOf("entitlement:true:1");
  const refundIndex = fixture.calls.indexOf("refund:create");
  const reversalIndex = fixture.calls.indexOf("reversal:wait");
  const cleanupIndex = fixture.calls.indexOf("subscription:delete");
  assert.ok(scheduleIndex < cancellationLedgerIndex);
  assert.ok(cancellationLedgerIndex < paidThroughEntitlementIndex);
  assert.ok(paidThroughEntitlementIndex < refundIndex);
  assert.ok(refundIndex < reversalIndex);
  assert.ok(reversalIndex < cleanupIndex);
});

test("fails closed before refund when the cancellation event is not scheduled at period end", async () => {
  const fixture = successfulFixture();
  fixture.events.set(
    "customer.subscription.updated",
    event(CANCEL_EVENT_ID, "customer.subscription.updated", {
      id: SUBSCRIPTION_ID,
      status: "active",
      cancel_at_period_end: false,
    }),
  );

  await assert.rejects(
    executeStagingStripeLifecycle(fixture.adapter),
    /customer\.subscription\.updated event was not found/u,
  );
  assert.equal(fixture.calls.includes("refund:create"), false);
});

test("fails closed before refund when cancellation scheduling does not leave the subscription active", async () => {
  const fixture = successfulFixture({
    adapter: {
      scheduleCancellation: async () => {
        fixture.calls.push("cancellation:schedule");
        return {
          id: SUBSCRIPTION_ID,
          status: "past_due",
          cancel_at_period_end: true,
        };
      },
    },
  });

  await assert.rejects(
    executeStagingStripeLifecycle(fixture.adapter),
    /must remain active after cancellation is scheduled/u,
  );
  assert.equal(fixture.calls.includes("refund:create"), false);
});

test("fails closed before refund when scheduled cancellation removes paid-through access", async () => {
  const fixture = successfulFixture();
  fixture.entitlements[1] = {
    ...fixture.entitlements[1],
    active: false,
  };

  await assert.rejects(
    executeStagingStripeLifecycle(fixture.adapter),
    /Expected values to be strictly equal:[\s\S]*false !== true/u,
  );
  assert.equal(fixture.calls.includes("refund:create"), false);
});

test("fails before cleanup when the refund does not create a durable reversal", async () => {
  const fixture = successfulFixture({
    adapter: {
      waitForPaymentReversal: async () => {
        fixture.calls.push("reversal:wait");
        return {
          reversed: false,
          reason: "not_reversed",
          subscriptionID: SUBSCRIPTION_ID,
          chargeID: CHARGE_ID,
        };
      },
    },
  });

  await assert.rejects(
    executeStagingStripeLifecycle(fixture.adapter),
    /false !== true/u,
  );
  assert.equal(fixture.calls.includes("subscription:delete"), false);
});

test("exact-SHA evidence is digest-sealed, private, and contains no raw provider ids", () => {
  const capturedAt = "2026-08-01T12:00:00.000Z";
  const evidence = buildLifecycleEvidence({
    candidate: {
      sha: CANDIDATE_SHA,
      tree: CANDIDATE_TREE,
      clean: true,
    },
    deployments: deployments(),
    proof: successfulProof(),
    capturedAt,
  });
  assert.equal(evidence.schema, STAGING_STRIPE_LIFECYCLE_SCHEMA);
  assert.equal(evidence.candidate.sha, CANDIDATE_SHA);
  assert.match(evidence.integrity.payloadDigest, /^[0-9a-f]{64}$/u);
  assert.equal(verifyLifecycleEvidence(evidence), true);

  const serialized = JSON.stringify(evidence);
  for (const rawIdentifier of [
    CHECKOUT_ID,
    CUSTOMER_ID,
    SUBSCRIPTION_ID,
    CHARGE_ID,
    REFUND_ID,
    CHECKOUT_EVENT_ID,
    CANCEL_EVENT_ID,
    REFUND_EVENT_ID,
  ]) {
    assert.equal(serialized.includes(rawIdentifier), false);
  }

  const root = mkdtempSync(
    join(tmpdir(), "openburnbar-stripe-lifecycle-evidence-"),
  );
  const outputDirectory = join(root, "launch-evidence");
  const paths = writeLifecycleEvidence(evidence, outputDirectory);
  assert.equal(statSync(outputDirectory).mode & 0o777, 0o700);
  assert.equal(statSync(paths.latestPath).mode & 0o777, 0o600);
  // Open once and derive both the mode check and the content read from the
  // same descriptor so there is no check-then-use window on the path.
  const outputFd = openSync(paths.outputPath, "r");
  try {
    assert.equal(fstatSync(outputFd).mode & 0o777, 0o600);
    assert.deepEqual(JSON.parse(readFileSync(outputFd, "utf8")), evidence);
  } finally {
    closeSync(outputFd);
  }
});

test("digest verification rejects a tampered lifecycle result", () => {
  const evidence = buildLifecycleEvidence({
    candidate: {
      sha: CANDIDATE_SHA,
      tree: CANDIDATE_TREE,
      clean: true,
    },
    deployments: deployments(),
    proof: successfulProof(),
    capturedAt: "2026-08-01T12:00:00.000Z",
  });
  evidence.lifecycle.refund.reversalReason = "tampered";
  assert.throws(
    () => verifyLifecycleEvidence(evidence),
    /lifecycle evidence digest mismatch/u,
  );
});

test("exact-SHA evidence rejects a stale deployed Function", () => {
  assert.throws(
    () => assertExactDeployment(deployments("c".repeat(40)), CANDIDATE_SHA),
    /not deployed from the expected candidate/u,
  );
});

test("the provider runner refuses mutation without an exact expected SHA", () => {
  const directory = dirname(fileURLToPath(import.meta.url));
  const runner = join(directory, "staging-stripe-lifecycle.mjs");
  const result = spawnSync(
    process.execPath,
    [runner, "--confirm", "burnbar-staging-commercial-lifecycle"],
    {
      encoding: "utf8",
    },
  );
  assert.notEqual(result.status, 0);
  assert.match(
    result.stderr,
    /--expected-sha must be the full deployed candidate SHA/u,
  );
});
