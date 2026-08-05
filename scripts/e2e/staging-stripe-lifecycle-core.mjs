import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { chmodSync, mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

export const STAGING_STRIPE_LIFECYCLE_SCHEMA =
  "openburnbar.staging-stripe-lifecycle-evidence.v1";
export const STAGING_STRIPE_ACCOUNT = "acct_1REg6cCFamvUJU7y";
export const STAGING_STRIPE_AMOUNT_CENTS = 799;
export const STAGING_STRIPE_CURRENCY = "usd";

const PRIVATE_DIRECTORY_MODE = 0o700;
const PRIVATE_FILE_MODE = 0o600;
const FULL_GIT_SHA = /^[0-9a-f]{40}$/u;

function requireIdentifier(value, pattern, label) {
  assert.equal(typeof value, "string", `${label} must be a string`);
  assert.match(value, pattern, `${label} has an unexpected shape`);
  return value;
}

function requireEvent(event, type, objectID) {
  assert.ok(event && typeof event === "object", `${type} event was not found`);
  requireIdentifier(event.id, /^evt_/u, `${type} event id`);
  assert.equal(event.type, type, `${type} event type mismatch`);
  assert.equal(
    event.data?.object?.id,
    objectID,
    `${type} event object mismatch`,
  );
  return event;
}

/**
 * Execute the exact staging commercial lifecycle against an injected provider
 * adapter. The adapter boundary lets deterministic tests prove operation order
 * and fail-closed assertions without contacting Stripe or Firebase.
 */
export async function executeStagingStripeLifecycle(adapter) {
  const account = await adapter.getStripeAccount();
  assert.equal(account.id, STAGING_STRIPE_ACCOUNT);

  const checkout = await adapter.createCheckout();
  const checkoutSessionID = requireIdentifier(
    checkout.sessionId,
    /^cs_test_/u,
    "Checkout Session id",
  );
  const checkoutURL = new URL(checkout.url);
  assert.equal(checkoutURL.protocol, "https:");
  assert.ok(
    checkoutURL.hostname === "checkout.stripe.com" ||
      checkoutURL.hostname === "pay.burnbar.ai",
    `Unexpected Stripe Checkout host: ${checkoutURL.hostname}`,
  );

  const openSession = await adapter.getCheckoutSession(checkoutSessionID);
  assert.equal(openSession.status, "open");
  assert.equal(openSession.mode, "subscription");
  assert.equal(openSession.livemode, false);
  assert.equal(openSession.amount_total, STAGING_STRIPE_AMOUNT_CENTS);
  assert.equal(openSession.currency, STAGING_STRIPE_CURRENCY);
  assert.equal(openSession.metadata?.entitlementID, "burnbar_pro");
  assert.equal(openSession.metadata?.tier, "cloud");
  assert.equal(openSession.metadata?.cadence, "monthly");
  const customerID = requireIdentifier(
    openSession.customer,
    /^cus_/u,
    "Stripe customer id",
  );

  const paymentMethod = await adapter.createPaymentMethod();
  requireIdentifier(paymentMethod.id, /^pm_/u, "Payment Method id");
  await adapter.confirmCheckout({
    checkoutSessionID,
    paymentMethodID: paymentMethod.id,
    expectedAmount: openSession.amount_total,
  });

  const completedSession =
    await adapter.waitForCompletedCheckout(checkoutSessionID);
  assert.equal(completedSession.status, "complete");
  assert.equal(completedSession.payment_status, "paid");
  const subscriptionID = requireIdentifier(
    completedSession.subscription,
    /^sub_/u,
    "Stripe subscription id",
  );

  const checkoutEvent = requireEvent(
    await adapter.findStripeEvent({
      type: "checkout.session.completed",
      objectID: checkoutSessionID,
    }),
    "checkout.session.completed",
    checkoutSessionID,
  );
  await adapter.waitForWebhookLedger(checkoutEvent.id);

  const activeEntitlement = await adapter.waitForEntitlement(true);
  assert.equal(activeEntitlement.active, true);
  assert.equal(activeEntitlement.platform, "stripe");
  assert.equal(activeEntitlement.externalSubscriptionID, subscriptionID);
  assert.equal(activeEntitlement.externalCustomerID, customerID);

  const portal = await adapter.createPortalSession();
  const portalURL = new URL(portal.url);
  assert.equal(portalURL.protocol, "https:");
  assert.ok(
    /(?:^|\.)stripe\.com$/u.test(portalURL.hostname) ||
      portalURL.hostname === "pay.burnbar.ai",
    `Unexpected Stripe billing portal host: ${portalURL.hostname}`,
  );

  // Prove the real customer cancellation policy before touching the money:
  // cancellation is scheduled at period end, its webhook is processed, and
  // the already-paid entitlement remains active until a refund reverses it.
  const scheduledCancellation =
    await adapter.scheduleCancellation(subscriptionID);
  assert.equal(scheduledCancellation.id, subscriptionID);
  assert.equal(scheduledCancellation.cancel_at_period_end, true);
  assert.equal(
    scheduledCancellation.status,
    "active",
    "The paid monthly subscription must remain active after cancellation is scheduled",
  );

  const cancellationScheduledEvent = requireEvent(
    await adapter.findStripeEvent({
      type: "customer.subscription.updated",
      objectID: subscriptionID,
      predicate: (event) => event.data?.object?.cancel_at_period_end === true,
    }),
    "customer.subscription.updated",
    subscriptionID,
  );
  assert.equal(
    cancellationScheduledEvent.data.object.cancel_at_period_end,
    true,
  );
  await adapter.waitForWebhookLedger(cancellationScheduledEvent.id);

  const paidThroughEntitlement = await adapter.waitForEntitlement(true);
  assert.equal(paidThroughEntitlement.active, true);
  assert.equal(paidThroughEntitlement.platform, "stripe");
  assert.equal(paidThroughEntitlement.externalSubscriptionID, subscriptionID);
  assert.equal(paidThroughEntitlement.externalCustomerID, customerID);
  assert.equal(paidThroughEntitlement.rawStatus, scheduledCancellation.status);
  assert.equal(
    paidThroughEntitlement.sourceEventID,
    cancellationScheduledEvent.id,
    "Cancellation update must be the entitlement's applied source event",
  );

  const charge = await adapter.findPaidCharge(customerID);
  const chargeID = requireIdentifier(charge?.id, /^ch_/u, "Stripe charge id");
  assert.equal(charge.paid, true);
  assert.notEqual(charge.refunded, true);

  const refund = await adapter.createRefund(chargeID);
  const refundID = requireIdentifier(refund.id, /^re_/u, "Stripe refund id");

  const refundEvent = requireEvent(
    await adapter.findStripeEvent({
      type: "charge.refunded",
      objectID: chargeID,
    }),
    "charge.refunded",
    chargeID,
  );
  await adapter.waitForWebhookLedger(refundEvent.id);

  const reversedEntitlement = await adapter.waitForEntitlement(false);
  assert.equal(reversedEntitlement.active, false);
  assert.equal(reversedEntitlement.platform, "stripe");
  assert.equal(reversedEntitlement.externalSubscriptionID, subscriptionID);
  assert.equal(reversedEntitlement.externalCustomerID, customerID);
  assert.equal(reversedEntitlement.rawStatus, "active:payment_reversed");

  const reversalMarker = await adapter.waitForPaymentReversal(subscriptionID);
  assert.equal(reversalMarker.reversed, true);
  assert.equal(reversalMarker.reason, "fully_refunded");
  assert.equal(reversalMarker.subscriptionID, subscriptionID);
  assert.equal(reversalMarker.chargeID, chargeID);

  // Immediate deletion is cleanup only. The business behavior was already
  // proven above: cancellation scheduled -> still entitled -> refund reversed.
  const deletedSubscription = await adapter.deleteSubscription(subscriptionID);
  assert.equal(deletedSubscription.id, subscriptionID);
  assert.equal(deletedSubscription.status, "canceled");

  const subscriptionDeletedEvent = requireEvent(
    await adapter.findStripeEvent({
      type: "customer.subscription.deleted",
      objectID: subscriptionID,
    }),
    "customer.subscription.deleted",
    subscriptionID,
  );
  await adapter.waitForWebhookLedger(subscriptionDeletedEvent.id);
  const cleanupEntitlement = await adapter.waitForEntitlement(false);
  assert.equal(cleanupEntitlement.active, false);
  assert.equal(cleanupEntitlement.rawStatus, "canceled");

  const deletedCustomer = await adapter.deleteCustomer(customerID);
  assert.equal(deletedCustomer.id, customerID);
  assert.equal(deletedCustomer.deleted, true);
  const customerDeletedEvent = requireEvent(
    await adapter.findStripeEvent({
      type: "customer.deleted",
      objectID: customerID,
    }),
    "customer.deleted",
    customerID,
  );
  await adapter.waitForWebhookLedger(customerDeletedEvent.id);

  return {
    checkout: {
      sessionID: checkoutSessionID,
      eventID: checkoutEvent.id,
      amountCents: openSession.amount_total,
      currency: openSession.currency,
      paymentStatus: completedSession.payment_status,
    },
    subscription: {
      subscriptionID,
      customerID,
      entitlementID: "burnbar_pro",
    },
    cancellation: {
      scheduled: true,
      cancelAtPeriodEnd: true,
      status: scheduledCancellation.status,
      eventID: cancellationScheduledEvent.id,
      entitlementRemainedActive: true,
    },
    refund: {
      chargeID,
      refundID,
      eventID: refundEvent.id,
      reversalReason: reversalMarker.reason,
      entitlementRawStatus: reversedEntitlement.rawStatus,
    },
    cleanup: {
      subscriptionDeletedEventID: subscriptionDeletedEvent.id,
      customerDeletedEventID: customerDeletedEvent.id,
      completed: true,
    },
    billingPortal: {
      sessionCreated: true,
    },
  };
}

export function assertExactDeployment(deployments, candidateSha) {
  assert.match(
    candidateSha,
    FULL_GIT_SHA,
    "candidate SHA must be a full Git SHA",
  );
  assert.ok(Array.isArray(deployments) && deployments.length > 0);
  for (const deployment of deployments) {
    assert.equal(
      deployment.state,
      "ACTIVE",
      `${deployment.name} is not ACTIVE`,
    );
    assert.equal(
      deployment.sourceCommit,
      candidateSha,
      `${deployment.name} is not deployed from the expected candidate`,
    );
    assert.equal(
      deployment.functionVersion,
      `staging-${candidateSha}`,
      `${deployment.name} version does not match the expected candidate`,
    );
    assert.match(
      deployment.revision,
      /^[a-z0-9-]+-\d{5}-[a-z0-9]+$/u,
      `${deployment.name} revision is missing`,
    );
  }
}

function digestIdentifier(identifier) {
  return `sha256:${createHash("sha256")
    .update(`openburnbar-stripe-evidence-v1\n${identifier}`, "utf8")
    .digest("hex")}`;
}

function redactLifecycleProof(proof) {
  return {
    checkout: {
      sessionDigest: digestIdentifier(proof.checkout.sessionID),
      eventDigest: digestIdentifier(proof.checkout.eventID),
      amountCents: proof.checkout.amountCents,
      currency: proof.checkout.currency,
      paymentStatus: proof.checkout.paymentStatus,
    },
    subscription: {
      subscriptionDigest: digestIdentifier(proof.subscription.subscriptionID),
      customerDigest: digestIdentifier(proof.subscription.customerID),
      entitlementID: proof.subscription.entitlementID,
    },
    cancellation: {
      scheduled: proof.cancellation.scheduled,
      cancelAtPeriodEnd: proof.cancellation.cancelAtPeriodEnd,
      status: proof.cancellation.status,
      eventDigest: digestIdentifier(proof.cancellation.eventID),
      entitlementRemainedActive: proof.cancellation.entitlementRemainedActive,
    },
    refund: {
      chargeDigest: digestIdentifier(proof.refund.chargeID),
      refundDigest: digestIdentifier(proof.refund.refundID),
      eventDigest: digestIdentifier(proof.refund.eventID),
      reversalReason: proof.refund.reversalReason,
      entitlementRawStatus: proof.refund.entitlementRawStatus,
    },
    cleanup: {
      subscriptionDeletedEventDigest: digestIdentifier(
        proof.cleanup.subscriptionDeletedEventID,
      ),
      customerDeletedEventDigest: digestIdentifier(
        proof.cleanup.customerDeletedEventID,
      ),
      completed: proof.cleanup.completed,
    },
    billingPortal: proof.billingPortal,
  };
}

export function buildLifecycleEvidence({
  candidate,
  deployments,
  proof,
  capturedAt = new Date().toISOString(),
}) {
  assert.match(candidate.sha, FULL_GIT_SHA);
  assert.match(candidate.tree, FULL_GIT_SHA);
  assert.equal(candidate.clean, true, "candidate checkout must be clean");
  assertExactDeployment(deployments, candidate.sha);

  const payload = {
    schema: STAGING_STRIPE_LIFECYCLE_SCHEMA,
    ok: true,
    capturedAt,
    environment: "staging",
    stripeMode: "test",
    candidate: {
      sha: candidate.sha,
      tree: candidate.tree,
      clean: true,
    },
    deployments: deployments.map((deployment) => ({
      name: deployment.name,
      state: deployment.state,
      revision: deployment.revision,
      sourceCommit: deployment.sourceCommit,
      functionVersion: deployment.functionVersion,
    })),
    lifecycle: redactLifecycleProof(proof),
  };
  const payloadDigest = createHash("sha256")
    .update(JSON.stringify(payload), "utf8")
    .digest("hex");
  return {
    ...payload,
    integrity: {
      algorithm: "sha256",
      payloadDigest,
    },
  };
}

export function verifyLifecycleEvidence(evidence) {
  assert.equal(evidence.schema, STAGING_STRIPE_LIFECYCLE_SCHEMA);
  assert.equal(evidence.ok, true);
  assert.equal(evidence.environment, "staging");
  assert.equal(evidence.stripeMode, "test");
  assert.match(evidence.candidate?.sha, FULL_GIT_SHA);
  assert.match(evidence.candidate?.tree, FULL_GIT_SHA);
  assert.equal(evidence.candidate?.clean, true);
  assertExactDeployment(evidence.deployments, evidence.candidate.sha);
  assert.equal(evidence.integrity?.algorithm, "sha256");
  assert.match(evidence.integrity?.payloadDigest, /^[0-9a-f]{64}$/u);

  const { integrity, ...payload } = evidence;
  const expectedDigest = createHash("sha256")
    .update(JSON.stringify(payload), "utf8")
    .digest("hex");
  assert.equal(
    integrity.payloadDigest,
    expectedDigest,
    "lifecycle evidence digest mismatch",
  );
  return true;
}

function writePrivateFile(path, body, options = {}) {
  if (options.flag !== "wx") {
    try {
      chmodSync(path, PRIVATE_FILE_MODE);
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
  }
  writeFileSync(path, body, {
    ...options,
    mode: PRIVATE_FILE_MODE,
  });
  chmodSync(path, PRIVATE_FILE_MODE);
}

export function writeLifecycleEvidence(
  evidence,
  outputDirectory = "launch-evidence",
) {
  const directory = resolve(outputDirectory);
  mkdirSync(directory, {
    recursive: true,
    mode: PRIVATE_DIRECTORY_MODE,
  });
  chmodSync(directory, PRIVATE_DIRECTORY_MODE);

  const stamp = evidence.capturedAt.replace(/[:.]/gu, "-");
  const shortSha = evidence.candidate.sha.slice(0, 12);
  const filename = `${stamp}-staging-stripe-lifecycle-${shortSha}-ok.json`;
  const outputPath = join(directory, filename);
  const latestPath = join(directory, "latest-staging-stripe-lifecycle.json");
  const body = `${JSON.stringify(evidence, null, 2)}\n`;
  writePrivateFile(outputPath, body, { flag: "wx" });
  writePrivateFile(latestPath, body);
  return { outputPath, latestPath, filename };
}
