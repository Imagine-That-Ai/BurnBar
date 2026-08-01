#!/usr/bin/env node

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";

import { loadStagingFirebasePublicConfig } from "../../website/scripts/staging-firebase-public-config.mjs";
import {
  assertExactDeployment,
  buildLifecycleEvidence,
  executeStagingStripeLifecycle,
  writeLifecycleEvidence,
} from "./staging-stripe-lifecycle-core.mjs";

const CONFIRMATION = "burnbar-staging-commercial-lifecycle";
const FULL_GIT_SHA = /^[0-9a-f]{40}$/u;
const DEFAULT_EVIDENCE_DIRECTORY = "launch-evidence";

function parseArgs(argv) {
  const options = {
    confirmation: "",
    expectedSha: "",
    evidenceDirectory: DEFAULT_EVIDENCE_DIRECTORY,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (
      arg === "--confirm" ||
      arg === "--expected-sha" ||
      arg === "--evidence-dir"
    ) {
      const value = argv[index + 1];
      if (!value || value.startsWith("--")) {
        throw new Error(`${arg} requires a value`);
      }
      if (arg === "--confirm") options.confirmation = value;
      if (arg === "--expected-sha") options.expectedSha = value;
      if (arg === "--evidence-dir") options.evidenceDirectory = value;
      index += 1;
      continue;
    }
    throw new Error(`Unknown argument: ${arg}`);
  }
  if (options.confirmation !== CONFIRMATION) {
    throw new Error(
      `Refusing to mutate staging without --confirm ${CONFIRMATION}`,
    );
  }
  if (!FULL_GIT_SHA.test(options.expectedSha)) {
    throw new Error("--expected-sha must be the full deployed candidate SHA");
  }
  return options;
}

const options = parseArgs(process.argv.slice(2));

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
const BILLING_FUNCTIONS = [
  "createStripeBurnBarProCheckoutSession",
  "createStripeBurnBarProPortalSession",
  "stripeBurnBarProWebhook",
];
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

function localCandidate(expectedSha) {
  const sha = run("git", ["rev-parse", "HEAD"]);
  assert.equal(
    sha,
    expectedSha,
    "The local checkout does not match --expected-sha",
  );
  const dirtyFiles = run("git", ["status", "--porcelain"]);
  assert.equal(
    dirtyFiles,
    "",
    "Refusing to produce exact-SHA evidence from a dirty checkout",
  );
  return {
    sha,
    tree: run("git", ["rev-parse", "HEAD^{tree}"]),
    clean: true,
  };
}

function deployedFunction(name, expectedSha) {
  const description = JSON.parse(
    run("gcloud", [
      "functions",
      "describe",
      name,
      "--gen2",
      "--region",
      "us-central1",
      "--project",
      PROJECT_ID,
      "--format=json",
    ]),
  );
  const environment = description.serviceConfig?.environmentVariables ?? {};
  const deployment = {
    name,
    state: description.state,
    revision: description.serviceConfig?.revision,
    sourceCommit: environment.OPENBURNBAR_SOURCE_COMMIT,
    functionVersion: environment.FUNCTION_VERSION,
  };
  assert.equal(
    deployment.sourceCommit,
    expectedSha,
    `${name} is not deployed from --expected-sha`,
  );
  return deployment;
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

async function findStripeEvent({ type, objectID, predicate = () => true }) {
  return retry(`${type} event`, async () => {
    const events = runStripe("get", [
      "/v1/events",
      "--data",
      `type=${type}`,
      "--data",
      "limit=20",
    ]);
    return events.data?.find(
      (event) => event.data?.object?.id === objectID && predicate(event),
    );
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
  const candidate = localCandidate(options.expectedSha);
  const deployments = BILLING_FUNCTIONS.map((name) =>
    deployedFunction(name, options.expectedSha),
  );
  assertExactDeployment(deployments, options.expectedSha);
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

  const proof = await executeStagingStripeLifecycle({
    getStripeAccount: () => stripeAccount,
    createCheckout: () =>
      callFunction(
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
      ),
    getCheckoutSession: (checkoutSessionID) => {
      const session = runStripe("get", [
        `/v1/checkout/sessions/${checkoutSessionID}`,
      ]);
      if (typeof session.customer === "string") {
        stripeCustomerID = session.customer;
      }
      return session;
    },
    createPaymentMethod: () =>
      runStripe("post", [
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
      ]),
    confirmCheckout: ({
      checkoutSessionID,
      paymentMethodID,
      expectedAmount,
    }) => {
      const confirmation = runStripe("post", [
        `/v1/payment_pages/${checkoutSessionID}/confirm`,
        "--data",
        `payment_method=${paymentMethodID}`,
        "--data",
        `expected_amount=${expectedAmount}`,
      ]);
      if (confirmation.error) {
        throw new Error(
          `Stripe Checkout confirmation failed: ${confirmation.error.message ?? "unknown error"}`,
        );
      }
      return confirmation;
    },
    waitForCompletedCheckout: (checkoutSessionID) =>
      retry("completed Checkout Session", async () => {
        const session = runStripe("get", [
          `/v1/checkout/sessions/${checkoutSessionID}`,
        ]);
        if (
          session.status !== "complete" ||
          typeof session.subscription !== "string"
        ) {
          return null;
        }
        stripeSubscriptionID = session.subscription;
        cleanupStripeSubscriptionID = session.subscription;
        return session;
      }),
    findStripeEvent,
    waitForWebhookLedger,
    waitForEntitlement,
    createPortalSession: () =>
      callFunction(
        "createStripeBurnBarProPortalSession",
        {
          returnUrl:
            "https://burnbar-staging.web.app/subscribe?tier=cloud&cadence=monthly",
        },
        appCheckToken,
      ),
    scheduleCancellation: (subscriptionID) =>
      runStripe("post", [
        `/v1/subscriptions/${subscriptionID}`,
        "--data",
        "cancel_at_period_end=true",
      ]),
    findPaidCharge: (customerID) => {
      const charges = runStripe("get", [
        "/v1/charges",
        "--data",
        `customer=${customerID}`,
        "--data",
        "limit=10",
      ]);
      return charges.data?.find(
        (candidateCharge) =>
          candidateCharge.paid === true && candidateCharge.refunded !== true,
      );
    },
    createRefund: (chargeID) =>
      runStripe("post", ["/v1/refunds", "--data", `charge=${chargeID}`]),
    waitForPaymentReversal: (subscriptionID) =>
      retry("Stripe payment-reversal marker", () =>
        readFirestoreDocument(`stripe_payment_reversals/${subscriptionID}`),
      ),
    deleteSubscription: (subscriptionID) => {
      const deleted = runStripe("delete", [
        `/v1/subscriptions/${subscriptionID}`,
        "--confirm",
      ]);
      stripeSubscriptionID = "";
      return deleted;
    },
    deleteCustomer: (customerID) => {
      const deleted = runStripe("delete", [
        `/v1/customers/${customerID}`,
        "--confirm",
      ]);
      stripeCustomerDeleted = deleted.deleted === true;
      return deleted;
    },
  });

  await cleanupFirestore();
  await deleteAuthUser();

  const evidence = buildLifecycleEvidence({
    candidate,
    deployments,
    proof,
  });
  const evidencePaths = writeLifecycleEvidence(
    evidence,
    options.evidenceDirectory,
  );
  lifecycleComplete = true;
  console.log(
    JSON.stringify(
      {
        schema: evidence.schema,
        ok: true,
        project: PROJECT_ID,
        stripeAccount: STRIPE_ACCOUNT,
        candidateSha: candidate.sha,
        candidateTree: candidate.tree,
        checkout: "completed",
        webhookLedger: "processed",
        entitlement: "active_then_cancel_scheduled_then_payment_reversed",
        billingPortal: "session_created",
        refund: "reconciled",
        cancellation: "scheduled_at_period_end_then_cleaned_up",
        cleanup: "completed",
        evidence: evidencePaths,
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
