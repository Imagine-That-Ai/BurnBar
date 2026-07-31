#!/usr/bin/env node
/**
 * Unit tests for commercial launch-gate requirement evaluators.
 */

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  COMMERCIAL_PRODUCTS,
  GOOGLE_PLAY_PRODUCTS,
  evaluateAppStoreProductReadiness,
  evaluateCloudRunServiceReadiness,
  evaluateElderWandHostedSearchRuntime,
  evaluateAlertDeliverabilityEvidence,
  evaluateEnvRequirements,
  evaluateHostedQuotaRunnerEndpoint,
  evaluateGooglePlayRtdnReadiness,
  evaluateRetiredCloudRunServiceAbsence,
  evaluateRemoteConfigDefaults,
  evaluateRequiredProductIDs,
  evaluateLatestMergedPrForMain,
  evaluateTrustedGitHubActionsCheckRun,
  actionsRunIdFromCheckRun,
  requiredVerifiableAlertChannels,
  verdict,
} from "./commercial-launch-gate.mjs";

const launchGateSource = readFileSync(
  new URL("./commercial-launch-gate.mjs", import.meta.url),
  "utf8",
);
assert.match(launchGateSource, /verifyCloudProTopUp/);
assert.match(launchGateSource, /verifyGooglePlayCloudProTopUp/);
assert.match(launchGateSource, /performElderWandHostedSearch/);
assert.match(launchGateSource, /cloud_pro_included_fusion_searches_monthly/);
assert.match(launchGateSource, /STRIPE_ELDER_WAND_SEARCHES_100_PRICE_ID/);
assert.match(launchGateSource, /READY_FOR_CANARY/);
assert.match(launchGateSource, /READY_FOR_PUBLIC_RELEASE/);
assert.match(launchGateSource, /LAUNCH_DONE/);
assert.match(launchGateSource, /prove:paid-tier/);
assert.match(launchGateSource, /validateLaunchEvidenceBundle/);
assert.match(launchGateSource, /firestoreDisasterRecovery/);
assert.match(launchGateSource, /googlePlayRtdn/);
assert.match(launchGateSource, /googlePlayDeveloperNotifications/);
assert.match(
  launchGateSource,
  /google-play-developer-notifications@system\.gserviceaccount\.com/,
);
assert.match(launchGateSource, /alertDeliverability/);
assert.match(launchGateSource, /openburnbar-hosted-mcp/);
assert.match(launchGateSource, /HOSTED_QUOTA_RUNNER_ALLOWED_HOSTS/);
assert.doesNotMatch(
  launchGateSource,
  /run\(\s*["']curl["']\s*,\s*\[[\s\S]{0,900}Authorization:\s*`?Bearer/u,
);
assert.doesNotMatch(
  launchGateSource,
  /["']-H["'][\s\S]{0,120}Authorization:\s*`?Bearer/u,
);

{
  const trustedCheck = {
    name: "Analyze (python)",
    status: "completed",
    conclusion: "success",
    completed_at: "2026-06-24T16:00:00Z",
    app: { slug: "github-actions" },
    details_url:
      "https://github.com/Imagine-That-Ai/BurnBar/actions/runs/123456/job/789",
  };
  assert.equal(actionsRunIdFromCheckRun(trustedCheck), "123456");
  assert.equal(
    evaluateTrustedGitHubActionsCheckRun(trustedCheck, {
      sha: "abc",
      workflowRun: {
        id: 123456,
        name: "CodeQL",
        path: ".github/workflows/codeql.yml",
        head_sha: "abc",
      },
      allowedWorkflowPaths: [".github/workflows/codeql.yml"],
    }).ok,
    true,
  );
  assert.equal(
    evaluateTrustedGitHubActionsCheckRun(
      { ...trustedCheck, app: { slug: "third-party-ci" } },
      {
        sha: "abc",
        workflowRun: {
          path: ".github/workflows/codeql.yml",
          head_sha: "abc",
        },
        allowedWorkflowPaths: [".github/workflows/codeql.yml"],
      },
    ).trust,
    "untrusted-check-app",
  );
  assert.equal(
    evaluateTrustedGitHubActionsCheckRun(trustedCheck, {
      sha: "abc",
      workflowRun: {
        path: ".github/workflows/spoof.yml",
        head_sha: "abc",
      },
      allowedWorkflowPaths: [".github/workflows/codeql.yml"],
    }).trust,
    "untrusted-workflow-path",
  );
  assert.equal(
    evaluateTrustedGitHubActionsCheckRun(trustedCheck, {
      sha: "abc",
      workflowRun: {
        path: ".github/workflows/codeql.yml",
        head_sha: "def",
      },
      allowedWorkflowPaths: [".github/workflows/codeql.yml"],
    }).trust,
    "workflow-run-head-sha-mismatch",
  );
}

{
  assert.equal(
    evaluateLatestMergedPrForMain({
      mainSha: "merge-sha",
      merged: {
        number: 835,
        head: { sha: "head-sha" },
        merge_commit_sha: "merge-sha",
      },
    }).ok,
    true,
  );
  const directMain = evaluateLatestMergedPrForMain({
    mainSha: "direct-main-sha",
    merged: {
      number: 835,
      head: { sha: "head-sha" },
      merge_commit_sha: "merge-sha",
    },
  });
  assert.equal(directMain.ok, false);
  assert.match(
    directMain.reason,
    /origin\/main has advanced past the latest merged PR/,
  );
}

assert.equal(
  GOOGLE_PLAY_PRODUCTS.cloudProMonthly,
  "com.openburnbar.promax.v2.monthly",
);
assert.equal(
  GOOGLE_PLAY_PRODUCTS.agentControlActions100,
  "com.openburnbar.agentcontrol.actions100",
);
assert.equal(
  GOOGLE_PLAY_PRODUCTS.elderWandSearches100,
  "com.openburnbar.elderwand.searches100",
);
assert.equal(
  GOOGLE_PLAY_PRODUCTS.elderWandSearches500,
  "com.openburnbar.elderwand.searches500",
);
assert.equal(
  COMMERCIAL_PRODUCTS.ultraAnnual,
  "com.openburnbar.ultra.annual.v2",
);
assert.equal(
  COMMERCIAL_PRODUCTS.elderWandSearches100,
  "com.openburnbar.elderWand.searches100",
);
assert.equal(
  COMMERCIAL_PRODUCTS.elderWandSearches500,
  "com.openburnbar.elderWand.searches500",
);
assert.equal(GOOGLE_PLAY_PRODUCTS.ultraAnnual, "com.openburnbar.ultra.annual");
assert.notEqual(
  GOOGLE_PLAY_PRODUCTS.cloudProMonthly,
  COMMERCIAL_PRODUCTS.cloudProMonthly,
);

function passingChecks(overrides = {}) {
  return {
    repo: { ok: true },
    appStore: { ok: true, state: "READY_FOR_SALE" },
    appStoreServerNotifications: { ok: true },
    firebaseAppCheck: { ok: true },
    branchProtection: { ok: true },
    githubSecurity: { ok: true },
    mainRequiredGate: { ok: true },
    mainCodeQL: { ok: true },
    latestMergedPrGate: { ok: true },
    cloudRun: { ok: true },
    runnerReadyz: { ok: true },
    redis: { ok: true },
    hostedQuotaRuntime: { ok: true },
    commercialBillingRuntime: { ok: true },
    elderWandHostedSearchRuntime: { ok: true },
    remoteConfigCaps: { ok: true },
    opsAlerts: { ok: true },
    billingAlerts: { ok: true },
    alertDeliverability: { ok: true },
    firestoreDisasterRecovery: { ok: true },
    googlePlayRtdn: { ok: true },
    firebaseFunctionsInventory: { ok: true },
    launchEvidence: {
      ok: true,
      stages: {
        paidProof: { ok: false, skipped: true },
        publicRelease: { ok: false, skipped: true },
        done: { ok: false, skipped: true },
      },
    },
    ...overrides,
  };
}

{
  assert.equal(verdict(passingChecks()).status, "READY_FOR_LIVE_PAID_PROOF");
  assert.equal(
    verdict(
      passingChecks({
        launchEvidence: {
          ok: true,
          stages: {
            paidProof: { ok: true },
            publicRelease: { ok: false },
            done: { ok: false },
          },
        },
      }),
    ).status,
    "READY_FOR_CANARY",
  );
  assert.equal(
    verdict(
      passingChecks({
        launchEvidence: {
          ok: true,
          stages: {
            paidProof: { ok: true },
            publicRelease: { ok: true },
            done: { ok: false },
          },
        },
      }),
    ).status,
    "READY_FOR_PUBLIC_RELEASE",
  );
  assert.equal(
    verdict(
      passingChecks({
        launchEvidence: {
          ok: true,
          stages: {
            paidProof: { ok: true },
            publicRelease: { ok: true },
            done: { ok: true },
          },
        },
      }),
    ).status,
    "LAUNCH_DONE",
  );
  assert.equal(
    verdict(passingChecks({ billingAlerts: { ok: false } })).status,
    "NO_GO",
  );
  assert.equal(
    verdict(passingChecks({ firestoreDisasterRecovery: { ok: false } })).status,
    "NO_GO",
  );
  assert.equal(
    verdict(passingChecks({ alertDeliverability: { ok: false } })).status,
    "NO_GO",
  );
  assert.equal(
    verdict(passingChecks({ googlePlayRtdn: { ok: false } })).status,
    "NO_GO",
  );
}

{
  const readiness = evaluateGooglePlayRtdnReadiness(
    {
      topic: {
        name: "projects/burnbar/topics/play-billing-notifications",
      },
      iamPolicy: {
        bindings: [
          {
            role: "roles/pubsub.publisher",
            members: [
              "serviceAccount:google-play-developer-notifications@system.gserviceaccount.com",
            ],
          },
        ],
      },
      functionDetails: {
        state: "ACTIVE",
        eventTrigger: {
          eventFilters: { topic: "play-billing-notifications" },
        },
        serviceConfig: {
          environmentVariables: {
            GOOGLE_PLAY_RTDN_TOPIC: "play-billing-notifications",
          },
        },
      },
      ttlFields: [
        {
          name:
            "projects/burnbar/databases/(default)/collectionGroups/" +
            "google_play_rtdn_events/fields/expireAt",
          ttlConfig: { state: "ACTIVE" },
        },
      ],
    },
    { project: "burnbar" },
  );
  assert.equal(readiness.ok, true);
  assert.equal(readiness.function.triggerTopic, readiness.topic.expected);
}

{
  const readiness = evaluateGooglePlayRtdnReadiness(
    {
      topic: {
        name: "projects/burnbar/topics/play-billing-notifications",
      },
      iamPolicy: { bindings: [] },
      functionDetails: {
        state: "ACTIVE",
        eventTrigger: {
          eventFilters: { topic: "play-billing-notifications" },
        },
        serviceConfig: {
          environmentVariables: {
            GOOGLE_PLAY_RTDN_TOPIC: "play-billing-notifications",
          },
        },
      },
      ttlFields: [
        {
          name:
            "projects/burnbar/databases/(default)/collectionGroups/" +
            "google_play_rtdn_events/fields/expireAt",
          ttlConfig: { state: "CREATING" },
        },
      ],
    },
    { project: "burnbar" },
  );
  assert.equal(readiness.ok, false);
  assert.equal(readiness.publisher.ok, false);
  assert.equal(readiness.ttl.ok, false);
}

{
  const coverage = evaluateRequiredProductIDs(
    [
      COMMERCIAL_PRODUCTS.cloudMonthly,
      COMMERCIAL_PRODUCTS.cloudAnnual,
      COMMERCIAL_PRODUCTS.cloudProMonthly,
      COMMERCIAL_PRODUCTS.cloudProAnnual,
      COMMERCIAL_PRODUCTS.ultraMonthly,
      COMMERCIAL_PRODUCTS.ultraAnnual,
      COMMERCIAL_PRODUCTS.agentControlActions100,
      COMMERCIAL_PRODUCTS.flooRelay50GB,
      COMMERCIAL_PRODUCTS.elderWandSearches100,
      COMMERCIAL_PRODUCTS.elderWandSearches500,
    ],
    [
      COMMERCIAL_PRODUCTS.cloudMonthly,
      COMMERCIAL_PRODUCTS.cloudAnnual,
      COMMERCIAL_PRODUCTS.cloudProMonthly,
      COMMERCIAL_PRODUCTS.cloudProAnnual,
      COMMERCIAL_PRODUCTS.ultraMonthly,
      COMMERCIAL_PRODUCTS.ultraAnnual,
      COMMERCIAL_PRODUCTS.agentControlActions100,
      COMMERCIAL_PRODUCTS.flooRelay50GB,
      COMMERCIAL_PRODUCTS.elderWandSearches100,
      COMMERCIAL_PRODUCTS.elderWandSearches500,
    ],
  );
  assert.equal(coverage.ok, true);
  assert.deepEqual(coverage.missing, []);
}

{
  const coverage = evaluateRequiredProductIDs(
    [COMMERCIAL_PRODUCTS.cloudMonthly],
    [COMMERCIAL_PRODUCTS.cloudMonthly, COMMERCIAL_PRODUCTS.cloudProMonthly],
  );
  assert.equal(coverage.ok, false);
  assert.deepEqual(coverage.missing, [COMMERCIAL_PRODUCTS.cloudProMonthly]);
}

{
  const readiness = evaluateAppStoreProductReadiness(
    {
      subscriptions: [
        {
          id: "sub_cloud_monthly",
          productId: COMMERCIAL_PRODUCTS.cloudMonthly,
          name: "BurnBar Cloud Monthly",
          state: "READY_TO_SUBMIT",
        },
        {
          id: "sub_cloud_pro_monthly",
          productId: COMMERCIAL_PRODUCTS.cloudProMonthly,
          name: "BurnBar Cloud Pro Monthly",
          state: "APPROVED",
        },
        {
          id: "sub_ultra_monthly",
          productId: COMMERCIAL_PRODUCTS.ultraMonthly,
          name: "BurnBar Ultra Monthly",
          state: "APPROVED",
        },
      ],
      inAppPurchases: [
        {
          id: "iap_actions",
          productId: COMMERCIAL_PRODUCTS.agentControlActions100,
          name: "Agent Control 100 Actions",
          state: "WAITING_FOR_REVIEW",
        },
        {
          id: "iap_elder_wand_100",
          productId: COMMERCIAL_PRODUCTS.elderWandSearches100,
          name: "Elder Wand Search 100",
          state: "WAITING_FOR_REVIEW",
        },
      ],
    },
    [
      COMMERCIAL_PRODUCTS.cloudMonthly,
      COMMERCIAL_PRODUCTS.cloudProMonthly,
      COMMERCIAL_PRODUCTS.ultraMonthly,
      COMMERCIAL_PRODUCTS.agentControlActions100,
      COMMERCIAL_PRODUCTS.elderWandSearches100,
    ],
  );
  assert.equal(readiness.ok, true);
}

{
  const readiness = evaluateAppStoreProductReadiness(
    {
      subscriptions: [
        {
          id: "sub_cloud_monthly",
          productId: COMMERCIAL_PRODUCTS.cloudMonthly,
          name: "BurnBar Cloud Monthly",
          state: "MISSING_METADATA",
        },
      ],
    },
    [COMMERCIAL_PRODUCTS.cloudMonthly, COMMERCIAL_PRODUCTS.cloudProMonthly],
  );
  assert.equal(readiness.ok, false);
  assert.deepEqual(
    readiness.checks.map((check) => [check.productId, check.state, check.ok]),
    [
      [COMMERCIAL_PRODUCTS.cloudMonthly, "MISSING_METADATA", false],
      [COMMERCIAL_PRODUCTS.cloudProMonthly, null, false],
    ],
  );
}

{
  const env = {
    STRIPE_BURNBAR_CLOUD_MONTHLY_PRICE_ID: "price_cloud_monthly",
    STRIPE_BURNBAR_PRO_PRICE_ID: "price_cloud_monthly",
    BURNBAR_PRO_PRODUCT_ID: COMMERCIAL_PRODUCTS.cloudMonthly,
  };
  const evaluated = evaluateEnvRequirements(
    env,
    {
      STRIPE_BURNBAR_PRO_PRICE_ID:
        "alias:STRIPE_BURNBAR_CLOUD_MONTHLY_PRICE_ID",
      BURNBAR_PRO_PRODUCT_ID: COMMERCIAL_PRODUCTS.cloudMonthly,
    },
    ["STRIPE_BURNBAR_CLOUD_MONTHLY_PRICE_ID"],
  );
  assert.equal(evaluated.ok, true);
}

{
  const env = {
    STRIPE_BURNBAR_CLOUD_MONTHLY_PRICE_ID: "price_cloud_monthly",
    STRIPE_BURNBAR_PRO_PRICE_ID: "price_legacy",
  };
  const evaluated = evaluateEnvRequirements(
    env,
    {
      STRIPE_BURNBAR_PRO_PRICE_ID:
        "alias:STRIPE_BURNBAR_CLOUD_MONTHLY_PRICE_ID",
    },
    [],
  );
  assert.equal(evaluated.ok, false);
  assert.equal(evaluated.valueChecks[0].actual, "price_legacy");
}

{
  const runtime = evaluateElderWandHostedSearchRuntime({
    ok: true,
    functionName: "performElderWandHostedSearch",
    env: { ENFORCE_APP_CHECK: "true" },
    secretEnvVarNames: ["PERPLEXITY_API_KEY", "TAVILY_API_KEY"],
  });
  assert.equal(runtime.ok, true);
}

{
  const runtime = evaluateElderWandHostedSearchRuntime({
    ok: true,
    functionName: "performElderWandHostedSearch",
    env: { ENFORCE_APP_CHECK: "true" },
    secretEnvVarNames: ["TAVILY_API_KEY"],
  });
  assert.equal(runtime.ok, false);
  assert.deepEqual(
    runtime.secretChecks.map((check) => [check.name, check.ok]),
    [
      ["PERPLEXITY_API_KEY", false],
      ["TAVILY_API_KEY", true],
    ],
  );
}

{
  const template = {
    parameters: {
      media_budget_soft_usd: { defaultValue: { value: "600" } },
      computer_use_budget_hard_usd: { defaultValue: { value: "2500" } },
    },
  };
  const evaluated = evaluateRemoteConfigDefaults(template, {
    media_budget_soft_usd: "600",
    computer_use_budget_hard_usd: "2500",
  });
  assert.equal(evaluated.ok, true);
}

{
  const template = {
    parameters: {
      media_budget_soft_usd: { defaultValue: { value: "500" } },
    },
  };
  const evaluated = evaluateRemoteConfigDefaults(template, {
    media_budget_soft_usd: "600",
  });
  assert.equal(evaluated.ok, false);
  assert.equal(evaluated.checks[0].actual, "500");
}

{
  const service = {
    status: {
      url: "https://openburnbar-quota-runner.example.run.app",
      conditions: [
        { type: "ConfigurationsReady", status: "True" },
        { type: "Ready", status: "True" },
      ],
    },
  };
  const readiness = evaluateCloudRunServiceReadiness(
    "openburnbar-quota-runner",
    service,
  );
  assert.deepEqual(readiness, {
    name: "openburnbar-quota-runner",
    exists: true,
    ready: true,
    url: "https://openburnbar-quota-runner.example.run.app",
    serviceAccount: null,
    ingress: null,
  });
}

{
  const readiness = evaluateCloudRunServiceReadiness(
    "openburnbar-quota-runner",
    {
      status: {
        conditions: [{ type: "Ready", status: "False" }],
      },
    },
  );
  assert.equal(readiness.ready, false);
}

{
  const endpoint = evaluateHostedQuotaRunnerEndpoint({
    configuredURL: "https://openburnbar-quota-runner-abc-uc.a.run.app/ignored",
    allowedHosts:
      "openburnbar-quota-runner-abc-uc.a.run.app,openburnbar-quota-runner-dr-uc.a.run.app",
    cloudRunURL: "https://openburnbar-quota-runner-abc-uc.a.run.app",
  });
  assert.equal(endpoint.ok, true);
  assert.equal(endpoint.host, "openburnbar-quota-runner-abc-uc.a.run.app");
  assert.equal(endpoint.allowedHostConfigured, true);
  assert.equal(endpoint.matchesCloudRunService, true);

  const untrusted = evaluateHostedQuotaRunnerEndpoint({
    configuredURL: "https://untrusted-runner.example",
    allowedHosts: "openburnbar-quota-runner-abc-uc.a.run.app",
    cloudRunURL: "https://openburnbar-quota-runner-abc-uc.a.run.app",
  });
  assert.equal(untrusted.ok, false);
  assert.equal(untrusted.allowedHostConfigured, false);
  assert.equal(untrusted.matchesCloudRunService, false);

  const credentialed = evaluateHostedQuotaRunnerEndpoint({
    configuredURL: "https://operator@openburnbar-quota-runner-abc-uc.a.run.app",
    allowedHosts: "openburnbar-quota-runner-abc-uc.a.run.app",
    cloudRunURL: "https://openburnbar-quota-runner-abc-uc.a.run.app",
  });
  assert.equal(credentialed.ok, false);
  assert.equal(credentialed.noUserInfo, false);
}

{
  const retired = evaluateRetiredCloudRunServiceAbsence(
    "hermes-realtime-relay",
    { ok: true, missing: true, name: "hermes-realtime-relay" },
  );
  assert.equal(retired.absent, true);
}

{
  const retired = evaluateRetiredCloudRunServiceAbsence(
    "hermes-realtime-relay",
    {
      ok: true,
      missing: false,
      name: "hermes-realtime-relay",
      service: { status: { url: "https://relay.example.run.app" } },
    },
  );
  assert.equal(retired.absent, false);
  assert.equal(retired.url, "https://relay.example.run.app");
}

{
  const alertChecks = [
    {
      required: [
        {
          displayName: "OpenBurnBar alert-delivery drill canary",
          notificationChannelStatuses: [
            {
              name: "projects/burnbar/notificationChannels/email",
              type: "email",
              target: "ops@burnbar.ai",
            },
          ],
        },
      ],
    },
  ];
  const required = requiredVerifiableAlertChannels(...alertChecks);
  assert.deepEqual(
    required.map((channel) => channel.name),
    ["projects/burnbar/notificationChannels/email"],
  );

  const fresh = evaluateAlertDeliverabilityEvidence(
    {
      generatedAt: "2026-06-17T12:00:00.000Z",
      channels: [
        {
          name: "projects/burnbar/notificationChannels/email",
          type: "email",
          deliveryConfirmed: true,
          deliveredAt: "2026-06-17T11:58:00.000Z",
          verifiedBy: "operator",
        },
      ],
    },
    required,
    { now: new Date("2026-06-17T12:30:00.000Z"), ttlHours: 168 },
  );
  assert.equal(fresh.ok, true);

  const stale = evaluateAlertDeliverabilityEvidence(
    {
      generatedAt: "2026-06-01T12:00:00.000Z",
      channels: [
        {
          name: "projects/burnbar/notificationChannels/email",
          type: "email",
          deliveryConfirmed: true,
          deliveredAt: "2026-06-01T12:00:00.000Z",
        },
      ],
    },
    required,
    { now: new Date("2026-06-17T12:30:00.000Z"), ttlHours: 168 },
  );
  assert.equal(stale.ok, false);
  assert.match(stale.failures.join("\n"), /older than 168h/);
}

console.log("commercial-launch-gate commercial evaluator tests passed");
