#!/usr/bin/env node

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";

import { loadStagingFirebasePublicConfig } from "../../website/scripts/staging-firebase-public-config.mjs";

const CONFIRMATION = "burnbar-staging-commercial-lifecycle";
const args = process.argv.slice(2);
const confirmIndex = args.indexOf("--confirm");
if (confirmIndex === -1 || args[confirmIndex + 1] !== CONFIRMATION) {
  throw new Error(
    `Refusing to mutate staging without --confirm ${CONFIRMATION}`,
  );
}

const PROJECT_ID = "burnbar-staging";
const STAGING_FIREBASE_PUBLIC_CONFIG = loadStagingFirebasePublicConfig();
const PROJECT_NUMBER =
  STAGING_FIREBASE_PUBLIC_CONFIG.PUBLIC_FIREBASE_MESSAGING_SENDER_ID;
const APP_ID = STAGING_FIREBASE_PUBLIC_CONFIG.PUBLIC_FIREBASE_APP_ID;
const API_KEY = STAGING_FIREBASE_PUBLIC_CONFIG.PUBLIC_FIREBASE_API_KEY;
const STRIPE_PROJECT = "openburnbar";
const STRIPE_ACCOUNT = "acct_1REg6cCFamvUJU7y";
const FUNCTIONS_ORIGIN = `https://us-central1-${PROJECT_ID}.cloudfunctions.net`;
const TEST_DISPLAY_NAME = "commercial-lifecycle-2026-07-26";
const POLL_ATTEMPTS = 30;
const POLL_DELAY_MS = 2_000;

let anonymousWasEnabled = false;
let anonymousWasChanged = false;
let debugTokenName = "";
let idToken = "";
let uid = "";
let stripeCustomerID = "";
let stripeSubscriptionID = "";
let cleanupStripeSubscriptionID = "";
let stripeCustomerDeleted = false;
let lifecycleComplete = false;

const sleep = (milliseconds) =>
  new Promise((resolvePromise) => setTimeout(resolvePromise, milliseconds));

function run(command, commandArgs) {
  return execFileSync(command, commandArgs, {
    encoding: "utf8",
    env: {
      ...process.env,
      STRIPE_CLI_TELEMETRY_OPTOUT: "1",
    },
  }).trim();
}

function gcloudAccessToken() {
  return run("gcloud", ["auth", "print-access-token"]);
}

function runStripe(command, commandArgs) {
  const stdout = run("stripe", [
    command,
    ...commandArgs,
    "--project-name",
    STRIPE_PROJECT,
    "--color",
    "off",
    "--log-level",
    "error",
  ]);
  try {
    return JSON.parse(stdout);
  } catch {
    throw new Error(
      `Stripe CLI returned non-JSON output for ${command} ${commandArgs[0]}`,
    );
  }
}

async function googleFetch(url, init = {}) {
  const response = await fetch(url, {
    ...init,
    headers: {
      authorization: `Bearer ${gcloudAccessToken()}`,
      "x-goog-user-project": PROJECT_ID,
      ...(init.headers ?? {}),
    },
  });
  const text = await response.text();
  const body = text ? JSON.parse(text) : {};
  if (!response.ok) {
    throw new Error(
      `Google API ${response.status}: ${body.error?.message ?? response.statusText}`,
    );
  }
  return body;
}

async function setAnonymousSignIn(enabled) {
  await googleFetch(
    `https://identitytoolkit.googleapis.com/admin/v2/projects/${PROJECT_ID}/config` +
      "?updateMask=signIn.anonymous.enabled",
    {
      method: "PATCH",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        signIn: { anonymous: { enabled } },
      }),
    },
  );
}

async function createDebugToken() {
  const debugSecret = randomUUID();
  const created = await googleFetch(
    `https://firebaseappcheck.googleapis.com/v1/projects/${PROJECT_NUMBER}` +
      `/apps/${APP_ID}/debugTokens`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        displayName: TEST_DISPLAY_NAME,
        token: debugSecret,
      }),
    },
  );
  debugTokenName = created.name;
  assert.match(
    debugTokenName,
    new RegExp(
      `^projects/${PROJECT_NUMBER}/apps/${APP_ID.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&")}/debugTokens/`,
      "u",
    ),
  );

  const response = await fetch(
    `https://content-firebaseappcheck.googleapis.com/v1/projects/${PROJECT_ID}` +
      `/apps/${APP_ID}:exchangeDebugToken?key=${API_KEY}`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ debug_token: debugSecret }),
    },
  );
  const body = await response.json();
  if (!response.ok) {
    throw new Error(
      `App Check debug exchange ${response.status}: ${body.error?.message ?? response.statusText}`,
    );
  }
  assert.ok(typeof body.token === "string" && body.token.length > 100);
  return body.token;
}

async function createAnonymousUser() {
  const response = await fetch(
    `https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${API_KEY}`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ returnSecureToken: true }),
    },
  );
  const body = await response.json();
  if (!response.ok) {
    throw new Error(
      `Anonymous test-user creation ${response.status}: ${body.error?.message ?? response.statusText}`,
    );
  }
  assert.ok(typeof body.idToken === "string" && body.idToken.length > 100);
  assert.ok(typeof body.localId === "string" && body.localId.length > 5);
  idToken = body.idToken;
  uid = body.localId;
}

async function callFunction(name, data, appCheckToken) {
  const response = await fetch(`${FUNCTIONS_ORIGIN}/${name}`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${idToken}`,
      "content-type": "application/json",
      "x-firebase-appcheck": appCheckToken,
    },
    body: JSON.stringify({ data }),
  });
  const body = await response.json();
  if (!response.ok || body.error) {
    throw new Error(
      `${name} ${response.status}: ${body.error?.message ?? response.statusText}`,
    );
  }
  return body.data ?? body.result;
}

function firestoreValue(value) {
  if (!value || typeof value !== "object") return undefined;
  if ("stringValue" in value) return value.stringValue;
  if ("booleanValue" in value) return value.booleanValue;
  if ("integerValue" in value) return Number(value.integerValue);
  if ("doubleValue" in value) return value.doubleValue;
  if ("timestampValue" in value) return value.timestampValue;
  if ("nullValue" in value) return null;
  if ("arrayValue" in value) {
    return (value.arrayValue.values ?? []).map(firestoreValue);
  }
  if ("mapValue" in value) {
    return firestoreFields(value.mapValue.fields ?? {});
  }
  return undefined;
}

function firestoreFields(fields) {
  return Object.fromEntries(
    Object.entries(fields).map(([key, value]) => [key, firestoreValue(value)]),
  );
}

async function readFirestoreDocument(path) {
  const response = await fetch(
    `https://firestore.googleapis.com/v1/projects/${PROJECT_ID}` +
      `/databases/(default)/documents/${path}`,
    {
      headers: {
        authorization: `Bearer ${gcloudAccessToken()}`,
        "x-goog-user-project": PROJECT_ID,
      },
    },
  );
  if (response.status === 404) return null;
  const body = await response.json();
  if (!response.ok) {
    throw new Error(
      `Firestore read ${response.status}: ${body.error?.message ?? response.statusText}`,
    );
  }
  return firestoreFields(body.fields ?? {});
}

async function deleteFirestoreDocument(path) {
  const response = await fetch(
    `https://firestore.googleapis.com/v1/projects/${PROJECT_ID}` +
      `/databases/(default)/documents/${path}`,
    {
      method: "DELETE",
      headers: {
        authorization: `Bearer ${gcloudAccessToken()}`,
        "x-goog-user-project": PROJECT_ID,
      },
    },
  );
  if (response.status !== 200 && response.status !== 404) {
    const body = await response.json();
    throw new Error(
      `Firestore delete ${response.status}: ${body.error?.message ?? response.statusText}`,
    );
  }
}

async function retry(label, operation) {
  let lastError;
  for (let attempt = 1; attempt <= POLL_ATTEMPTS; attempt += 1) {
    try {
      const value = await operation();
      if (value !== undefined && value !== null && value !== false)
        return value;
    } catch (error) {
      lastError = error;
    }
    if (attempt < POLL_ATTEMPTS) await sleep(POLL_DELAY_MS);
  }
  throw new Error(
    `${label} did not converge${lastError ? `: ${lastError}` : ""}`,
  );
}

async function findStripeEvent(type, objectID) {
  return retry(`${type} event`, async () => {
    const events = runStripe("get", [
      "/v1/events",
      "--data",
      `type=${type}`,
      "--data",
      "limit=20",
    ]);
    return events.data?.find((event) => event.data?.object?.id === objectID);
  });
}

async function waitForWebhookLedger(eventID) {
  return retry(`webhook ledger ${eventID}`, async () => {
    const ledger = await readFirestoreDocument(
      `stripe_webhook_events/${eventID}`,
    );
    if (ledger?.status === "failed") {
      throw new Error(`Stripe webhook ${eventID} recorded failure`);
    }
    return ledger?.status === "processed" ? ledger : null;
  });
}

async function waitForEntitlement(expectedActive) {
  return retry(`burnbar_pro active=${expectedActive}`, async () => {
    const entitlement = await readFirestoreDocument(
      `users/${uid}/entitlements/burnbar_pro`,
    );
    return entitlement?.active === expectedActive ? entitlement : null;
  });
}

async function deleteAuthUser() {
  if (!idToken) return;
  const response = await fetch(
    `https://identitytoolkit.googleapis.com/v1/accounts:delete?key=${API_KEY}`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ idToken }),
    },
  );
  if (!response.ok) {
    const body = await response.json();
    throw new Error(
      `Test-user deletion ${response.status}: ${body.error?.message ?? response.statusText}`,
    );
  }
  idToken = "";
}

async function cleanupFirestore() {
  if (!uid) return;
  await Promise.all([
    deleteFirestoreDocument(`users/${uid}/entitlements/burnbar_pro`),
    deleteFirestoreDocument(`users/${uid}/billing/stripe`),
    deleteFirestoreDocument(`users/${uid}`),
    stripeCustomerID
      ? deleteFirestoreDocument(`stripe_customers/${stripeCustomerID}`)
      : Promise.resolve(),
    cleanupStripeSubscriptionID
      ? deleteFirestoreDocument(
          `stripe_payment_reversals/${cleanupStripeSubscriptionID}`,
        )
      : Promise.resolve(),
  ]);
}

try {
  const stripeAccount = runStripe("get", ["/v1/account"]);
  assert.equal(stripeAccount.id, STRIPE_ACCOUNT);

  const identityConfig = await googleFetch(
    `https://identitytoolkit.googleapis.com/admin/v2/projects/${PROJECT_ID}/config`,
  );
  anonymousWasEnabled = identityConfig.signIn?.anonymous?.enabled === true;
  if (!anonymousWasEnabled) {
    await setAnonymousSignIn(true);
    anonymousWasChanged = true;
  }

  const appCheckToken = await createDebugToken();
  await createAnonymousUser();

  const checkout = await callFunction(
    "createStripeBurnBarProCheckoutSession",
    {
      successUrl:
        "https://burnbar-staging.web.app/subscribe?tier=cloud&cadence=monthly&status=success",
      cancelUrl:
        "https://burnbar-staging.web.app/subscribe?tier=cloud&cadence=monthly&status=cancelled",
      tier: "cloud",
      cadence: "monthly",
    },
    appCheckToken,
  );
  assert.match(checkout.sessionId, /^cs_test_/u);
  const checkoutURL = new URL(checkout.url);
  assert.equal(checkoutURL.protocol, "https:");
  assert.ok(
    checkoutURL.hostname === "checkout.stripe.com" ||
      checkoutURL.hostname === "pay.burnbar.ai",
    `Unexpected Stripe Checkout host: ${checkoutURL.hostname}`,
  );

  const openSession = runStripe("get", [
    `/v1/checkout/sessions/${checkout.sessionId}`,
  ]);
  assert.equal(openSession.status, "open");
  assert.equal(openSession.mode, "subscription");
  assert.ok(Number.isSafeInteger(openSession.amount_total));
  assert.ok(openSession.amount_total > 0);
  stripeCustomerID = openSession.customer;
  assert.match(stripeCustomerID, /^cus_/u);

  const paymentMethod = runStripe("post", [
    "/v1/payment_methods",
    "--data",
    "type=card",
    "--data",
    "card[token]=tok_visa",
    "--data",
    "billing_details[name]=BurnBar Commercial Lifecycle",
    "--data",
    "billing_details[email]=commercial-lifecycle@burnbar.invalid",
    "--data",
    "billing_details[address][line1]=100 SW Main St",
    "--data",
    "billing_details[address][city]=Portland",
    "--data",
    "billing_details[address][state]=OR",
    "--data",
    "billing_details[address][postal_code]=97204",
    "--data",
    "billing_details[address][country]=US",
  ]);
  assert.match(paymentMethod.id, /^pm_/u);

  const confirmation = runStripe("post", [
    `/v1/payment_pages/${checkout.sessionId}/confirm`,
    "--data",
    `payment_method=${paymentMethod.id}`,
    "--data",
    `expected_amount=${openSession.amount_total}`,
  ]);
  if (confirmation.error) {
    throw new Error(
      `Stripe Checkout confirmation failed: ${confirmation.error.message ?? "unknown error"}`,
    );
  }

  const completedSession = await retry(
    "completed Checkout Session",
    async () => {
      const session = runStripe("get", [
        `/v1/checkout/sessions/${checkout.sessionId}`,
      ]);
      return session.status === "complete" && session.subscription
        ? session
        : null;
    },
  );
  stripeSubscriptionID = completedSession.subscription;
  assert.match(stripeSubscriptionID, /^sub_/u);
  cleanupStripeSubscriptionID = stripeSubscriptionID;

  const checkoutEvent = await findStripeEvent(
    "checkout.session.completed",
    checkout.sessionId,
  );
  await waitForWebhookLedger(checkoutEvent.id);
  const activeEntitlement = await waitForEntitlement(true);
  assert.equal(activeEntitlement.platform, "stripe");
  assert.equal(activeEntitlement.externalSubscriptionID, stripeSubscriptionID);
  assert.equal(activeEntitlement.externalCustomerID, stripeCustomerID);

  const portal = await callFunction(
    "createStripeBurnBarProPortalSession",
    {
      returnUrl:
        "https://burnbar-staging.web.app/subscribe?tier=cloud&cadence=monthly",
    },
    appCheckToken,
  );
  const portalURL = new URL(portal.url);
  assert.equal(portalURL.protocol, "https:");
  assert.ok(
    /(?:^|\.)stripe\.com$/u.test(portalURL.hostname) ||
      portalURL.hostname === "pay.burnbar.ai",
    `Unexpected Stripe billing portal host: ${portalURL.hostname}`,
  );

  const charges = runStripe("get", [
    "/v1/charges",
    "--data",
    `customer=${stripeCustomerID}`,
    "--data",
    "limit=10",
  ]);
  const charge = charges.data?.find(
    (candidate) => candidate.paid === true && candidate.refunded !== true,
  );
  assert.match(charge?.id ?? "", /^ch_/u);

  const refund = runStripe("post", [
    "/v1/refunds",
    "--data",
    `charge=${charge.id}`,
  ]);
  assert.match(refund.id, /^re_/u);

  const refundEvent = await findStripeEvent("charge.refunded", charge.id);
  await waitForWebhookLedger(refundEvent.id);
  const reversedEntitlement = await waitForEntitlement(false);
  assert.equal(reversedEntitlement.rawStatus, "active:payment_reversed");
  const reversalMarker = await retry("Stripe payment-reversal marker", () =>
    readFirestoreDocument(
      `stripe_payment_reversals/${cleanupStripeSubscriptionID}`,
    ),
  );
  assert.equal(reversalMarker.reversed, true);
  assert.equal(reversalMarker.reason, "fully_refunded");

  const cancelled = runStripe("delete", [
    `/v1/subscriptions/${stripeSubscriptionID}`,
    "--confirm",
  ]);
  assert.equal(cancelled.status, "canceled");

  const cancellationEvent = await findStripeEvent(
    "customer.subscription.deleted",
    stripeSubscriptionID,
  );
  await waitForWebhookLedger(cancellationEvent.id);
  const inactiveEntitlement = await waitForEntitlement(false);
  assert.equal(inactiveEntitlement.rawStatus, "canceled");
  stripeSubscriptionID = "";

  const deletedCustomer = runStripe("delete", [
    `/v1/customers/${stripeCustomerID}`,
    "--confirm",
  ]);
  assert.equal(deletedCustomer.deleted, true);
  const customerDeletionEvent = await findStripeEvent(
    "customer.deleted",
    stripeCustomerID,
  );
  await waitForWebhookLedger(customerDeletionEvent.id);
  stripeCustomerDeleted = true;

  await cleanupFirestore();
  await deleteAuthUser();

  lifecycleComplete = true;
  console.log(
    JSON.stringify(
      {
        project: PROJECT_ID,
        stripeAccount: STRIPE_ACCOUNT,
        checkout: "completed",
        webhookLedger: "processed",
        entitlement: "active_then_canceled",
        billingPortal: "session_created",
        refund: "reconciled",
        cancellation: "reconciled",
        cleanup: "completed",
      },
      null,
      2,
    ),
  );
} finally {
  if (stripeSubscriptionID) {
    try {
      runStripe("delete", [
        `/v1/subscriptions/${stripeSubscriptionID}`,
        "--confirm",
      ]);
    } catch {
      // Best-effort cleanup after a failed proof.
    }
  }
  if (stripeCustomerID && !stripeCustomerDeleted) {
    try {
      runStripe("delete", [`/v1/customers/${stripeCustomerID}`, "--confirm"]);
    } catch {
      // Best-effort cleanup after a failed proof.
    }
  }
  try {
    await cleanupFirestore();
  } catch {
    // Best-effort cleanup after a failed proof.
  }
  try {
    await deleteAuthUser();
  } catch {
    // Best-effort cleanup after a failed proof.
  }
  if (debugTokenName) {
    try {
      await googleFetch(
        `https://firebaseappcheck.googleapis.com/v1/${debugTokenName}`,
        { method: "DELETE" },
      );
    } catch {
      // Best-effort cleanup after a failed proof.
    }
  }
  if (anonymousWasChanged) {
    await setAnonymousSignIn(anonymousWasEnabled);
  }
  if (!lifecycleComplete) {
    console.error(
      "Staging Stripe lifecycle proof failed; reversible cleanup attempted.",
    );
  }
}
