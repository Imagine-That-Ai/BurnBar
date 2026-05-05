#!/usr/bin/env node
/**
 * Creates or updates the Firebase Auth + Firestore account used by App Review.
 *
 * Credentials are intentionally provided through environment variables so no
 * reviewer password is committed to the repo:
 *
 *   OPENBURNBAR_REVIEW_EMAIL=app-reviewer@example.com \
 *   OPENBURNBAR_REVIEW_PASSWORD='...' \
 *   node tools/app-store-connect/seed-review-account.js
 */

function loadFirebaseAdmin() {
  try {
    return require("firebase-admin");
  } catch {
    return require("../../functions/node_modules/firebase-admin");
  }
}

const admin = loadFirebaseAdmin();

const PROJECT_ID = process.env.FIREBASE_PROJECT || process.env.GCLOUD_PROJECT || "burnbar";
const REVIEW_EMAIL = requiredEnv("OPENBURNBAR_REVIEW_EMAIL").trim().toLowerCase();
const REVIEW_PASSWORD = requiredEnv("OPENBURNBAR_REVIEW_PASSWORD");
const DISPLAY_NAME = process.env.OPENBURNBAR_REVIEW_DISPLAY_NAME || "OpenBurnBar App Review";

function requiredEnv(name) {
  const value = process.env[name];
  if (!value || value.trim().length === 0) {
    throw new Error(`${name} is required`);
  }
  return value;
}

function dayKey(date) {
  return date.toISOString().slice(0, 10);
}

function daysAgo(days) {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() - days);
  return d;
}

function minutesAgo(minutes) {
  return new Date(Date.now() - minutes * 60 * 1000);
}

function iso(date) {
  return date.toISOString();
}

function usageDoc({
  id,
  provider,
  providerID,
  accountID,
  accountLabel,
  accountSource,
  sessionId,
  projectName,
  model,
  inputTokens,
  outputTokens,
  cacheCreationTokens = 0,
  cacheReadTokens = 0,
  reasoningTokens = 0,
  cost,
  minutes,
  deviceId,
  deviceName,
  usageSource = "provider_log",
  provenanceMethod = "provider_log",
  provenanceConfidence = "exact",
}) {
  const totalTokens =
    inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens + reasoningTokens;
  const end = minutesAgo(minutes);
  const start = new Date(end.getTime() - 18 * 60 * 1000);
  return [
    id,
    {
      id,
      provider,
      providerID,
      providerAccountID: accountID,
      providerAccountLabel: accountLabel,
      providerAccountSource: accountSource,
      model,
      sessionId,
      projectName,
      deviceId,
      sourceDeviceId: deviceId,
      sourceDeviceName: deviceName,
      inputTokens,
      outputTokens,
      cacheCreationTokens,
      cacheReadTokens,
      reasoningTokens,
      totalTokens,
      cost,
      costUsd: cost,
      startTime: iso(start),
      endTime: iso(end),
      timestamp: iso(start),
      createdAt: iso(end),
      updatedAt: iso(end),
      usageSource,
      isRemote: deviceId !== "review-macbook-pro",
      provenanceMethod,
      provenanceConfidence,
      estimatorVersion: "app-review-seed-v1",
      schemaVersion: 2,
    },
  ];
}

function quotaSnapshot({
  id,
  provider,
  providerID,
  accountID,
  accountLabel,
  accountStorageScope,
  sourceKind,
  source,
  sourceId,
  confidence,
  statusMessage,
  managementURL,
  buckets,
  minutes,
}) {
  const fetchedAt = minutesAgo(minutes);
  return [
    id,
    {
      id,
      provider,
      providerID,
      accountID,
      accountLabel,
      accountStorageScope,
      sourceKind,
      source,
      sourceId,
      confidence,
      statusMessage,
      managementURL,
      buckets,
      fetchedAt: iso(fetchedAt),
      updatedAt: iso(fetchedAt),
      schemaVersion: 2,
    },
  ];
}

function providerAccount({
  id,
  providerID,
  label,
  identityHint,
  credentialKind,
  storageScope,
  redactedLabel,
  sourceDeviceID,
  isDefault,
  sortKey,
  minutes,
}) {
  const refreshedAt = minutesAgo(minutes);
  return [
    id,
    {
      id,
      providerID,
      label,
      identityHint,
      status: "connected",
      credentialKind,
      storageScope,
      redactedLabel,
      sourceDeviceID,
      isDefault,
      sortKey,
      lastValidatedAt: iso(refreshedAt),
      lastRefreshAt: iso(refreshedAt),
      schemaVersion: 1,
      createdAt: iso(daysAgo(18)),
      updatedAt: iso(refreshedAt),
    },
  ];
}

function providerConnection({ provider, credentialKind, redactedLabel, minutes }) {
  const refreshedAt = minutesAgo(minutes);
  return [
    provider,
    {
      id: provider,
      provider,
      status: "connected",
      lastValidatedAt: iso(refreshedAt),
      lastRefreshAt: iso(refreshedAt),
      credentialKind,
      redactedLabel,
      schemaVersion: 1,
    },
  ];
}

function rollup(windowKey, { requests, tokens, costUsd, days }) {
  const pointCount = Math.min(days, 14);
  const dailyPoints = {};
  for (let i = pointCount - 1; i >= 0; i -= 1) {
    const weight = 0.72 + ((pointCount - i) % 5) * 0.11;
    dailyPoints[dayKey(daysAgo(i))] = Math.round((tokens / pointCount) * weight);
  }
  return [
    windowKey,
    {
      today: windowKey === "today" ? tokens : 0,
      "7d": windowKey === "7d" ? tokens : 0,
      "30d": windowKey === "30d" ? tokens : 0,
      "90d": windowKey === "90d" ? tokens : 0,
      all_time: windowKey === "all_time" ? tokens : 0,
      totals: { requests, tokens, costUsd },
      providerSummaries: [
        {
          provider: "Codex",
          providerID: "codex",
          totalRequests: Math.round(requests * 0.43),
          totalTokens: Math.round(tokens * 0.44),
          totalCost: Number((costUsd * 0.41).toFixed(2)),
        },
        {
          provider: "Claude Code",
          providerID: "claude-code",
          totalRequests: Math.round(requests * 0.36),
          totalTokens: Math.round(tokens * 0.39),
          totalCost: Number((costUsd * 0.43).toFixed(2)),
        },
        {
          provider: "OpenAI",
          providerID: "openai",
          totalRequests: Math.round(requests * 0.21),
          totalTokens: Math.round(tokens * 0.17),
          totalCost: Number((costUsd * 0.16).toFixed(2)),
        },
      ],
      accountSummaries: [
        {
          id: "codex-hosted",
          providerID: "codex",
          accountID: "codex-hosted",
          accountLabel: "Hosted Codex",
          storageScope: "server_private",
          totalRequests: Math.round(requests * 0.43),
          totalTokens: Math.round(tokens * 0.44),
          totalCost: Number((costUsd * 0.41).toFixed(2)),
        },
        {
          id: "claude-local",
          providerID: "claude-code",
          accountID: "claude-local",
          accountLabel: "MacBook Pro",
          storageScope: "local_only",
          totalRequests: Math.round(requests * 0.36),
          totalTokens: Math.round(tokens * 0.39),
          totalCost: Number((costUsd * 0.43).toFixed(2)),
        },
      ],
      modelSummaries: [
        {
          model: "gpt-5.4-codex",
          provider: "Codex",
          requests: Math.round(requests * 0.43),
          tokens: Math.round(tokens * 0.44),
          cost: Number((costUsd * 0.41).toFixed(2)),
        },
        {
          model: "claude-sonnet-4.5",
          provider: "Claude Code",
          requests: Math.round(requests * 0.36),
          tokens: Math.round(tokens * 0.39),
          cost: Number((costUsd * 0.43).toFixed(2)),
        },
      ],
      deviceSummaries: [
        {
          deviceId: "review-macbook-pro",
          requests: Math.round(requests * 0.78),
          tokens: Math.round(tokens * 0.83),
        },
        {
          deviceId: "review-ipad-pro",
          requests: Math.round(requests * 0.22),
          tokens: Math.round(tokens * 0.17),
        },
      ],
      dailyPoints,
      computedAt: iso(new Date()),
      schemaVersion: 1,
    },
  ];
}

async function upsertReviewUser() {
  const auth = admin.auth();
  try {
    const existing = await auth.getUserByEmail(REVIEW_EMAIL);
    await auth.updateUser(existing.uid, {
      password: REVIEW_PASSWORD,
      displayName: DISPLAY_NAME,
      emailVerified: true,
      disabled: false,
    });
    return existing.uid;
  } catch (error) {
    if (error.code !== "auth/user-not-found") throw error;
    const created = await auth.createUser({
      email: REVIEW_EMAIL,
      password: REVIEW_PASSWORD,
      displayName: DISPLAY_NAME,
      emailVerified: true,
      disabled: false,
    });
    return created.uid;
  }
}

async function seedFirestore(uid) {
  const db = admin.firestore();
  db.settings({ ignoreUndefinedProperties: true });
  const userRef = db.doc(`users/${uid}`);
  const batch = db.batch();
  const now = new Date();

  batch.set(
    userRef,
    {
      displayName: DISPLAY_NAME,
      email: REVIEW_EMAIL,
      reviewSeed: true,
      reviewSeedVersion: 1,
      updatedAt: iso(now),
    },
    { merge: true }
  );

  const devices = [
    [
      "review-macbook-pro",
      {
        deviceId: "review-macbook-pro",
        deviceName: "Review MacBook Pro",
        platform: "macOS",
        appVersion: "1.0",
        lastActiveAt: iso(minutesAgo(8)),
      },
    ],
    [
      "review-ipad-pro",
      {
        deviceId: "review-ipad-pro",
        deviceName: "Review iPad Pro",
        platform: "iPadOS",
        appVersion: "1.0",
        lastActiveAt: iso(minutesAgo(3)),
      },
    ],
  ];
  for (const [id, doc] of devices) {
    batch.set(userRef.collection("devices").doc(id), doc, { merge: true });
  }

  batch.set(
    userRef.collection("sync_status").doc("review-macbook-pro"),
    {
      deviceId: "review-macbook-pro",
      lastSyncAt: iso(minutesAgo(8)),
      usageCount: 12,
      quotaSnapshotCount: 3,
      lastError: null,
      schemaVersion: 1,
    },
    { merge: true }
  );

  for (const [id, doc] of [
    providerAccount({
      id: "codex-hosted",
      providerID: "codex",
      label: "Hosted Codex",
      identityHint: "App Review entitlement",
      credentialKind: "session",
      storageScope: "server_private",
      redactedLabel: "OpenBurnBar hosted sync",
      isDefault: true,
      sortKey: 0,
      minutes: 7,
    }),
    providerAccount({
      id: "claude-local",
      providerID: "claude-code",
      label: "MacBook Pro",
      identityHint: "Self-hosted runner",
      credentialKind: "session",
      storageScope: "local_only",
      redactedLabel: "Local runner",
      sourceDeviceID: "review-macbook-pro",
      isDefault: true,
      sortKey: 1,
      minutes: 12,
    }),
    providerAccount({
      id: "openai-team",
      providerID: "openai",
      label: "OpenAI Team",
      identityHint: "Review workspace",
      credentialKind: "token",
      storageScope: "cloud_refreshable",
      redactedLabel: "sk-...review",
      isDefault: false,
      sortKey: 2,
      minutes: 18,
    }),
  ]) {
    batch.set(userRef.collection("provider_accounts").doc(id), doc, { merge: true });
  }

  for (const [id, doc] of [
    providerConnection({
      provider: "Codex",
      credentialKind: "session",
      redactedLabel: "Hosted Codex",
      minutes: 7,
    }),
    providerConnection({
      provider: "Claude Code",
      credentialKind: "session",
      redactedLabel: "MacBook Pro self-hosted runner",
      minutes: 12,
    }),
    providerConnection({
      provider: "OpenAI",
      credentialKind: "token",
      redactedLabel: "OpenAI Team",
      minutes: 18,
    }),
  ]) {
    batch.set(userRef.collection("provider_connections").doc(id), doc, { merge: true });
  }

  for (const [id, doc] of [
    quotaSnapshot({
      id: "codex_codex-hosted_hosted",
      provider: "Codex",
      providerID: "codex",
      accountID: "codex-hosted",
      accountLabel: "Hosted Codex",
      accountStorageScope: "server_private",
      sourceKind: "provider",
      source: "Hosted on-demand refresh",
      sourceId: "hosted",
      confidence: "high",
      statusMessage:
        "Updated on demand from OpenBurnBar hosted sync. Refreshes happen only when the user taps refresh.",
      managementURL: "https://chatgpt.com/codex",
      buckets: [
        { name: "Weekly messages", used: 147, limit: 300, remaining: 153, window: "rolling week" },
        { name: "Today", used: 6, limit: 30, remaining: 24, window: "daily" },
      ],
      minutes: 7,
    }),
    quotaSnapshot({
      id: "claude-code_claude-local_self-hosted",
      provider: "Claude Code",
      providerID: "claude-code",
      accountID: "claude-local",
      accountLabel: "MacBook Pro",
      accountStorageScope: "local_only",
      sourceKind: "localCLI",
      source: "Self-hosted Mac runner",
      sourceId: "self-hosted",
      confidence: "medium",
      statusMessage:
        "Claude Code quota was uploaded by a self-hosted runner after a manual refresh.",
      managementURL: "https://claude.ai/settings",
      buckets: [
        { name: "Plan window", used: 82, limit: 100, remaining: 18, window: "rolling" },
        { name: "Fast lane", used: 21, limit: 40, remaining: 19, window: "daily" },
      ],
      minutes: 12,
    }),
    quotaSnapshot({
      id: "openai_openai-team_api",
      provider: "OpenAI",
      providerID: "openai",
      accountID: "openai-team",
      accountLabel: "OpenAI Team",
      accountStorageScope: "cloud_refreshable",
      sourceKind: "officialAPI",
      source: "OpenAI usage API",
      sourceId: "usage-api",
      confidence: "high",
      statusMessage: "Healthy monthly budget headroom.",
      managementURL: "https://platform.openai.com/usage",
      buckets: [
        { name: "Monthly budget", used: 218, limit: 500, remaining: 282, window: "monthly" },
      ],
      minutes: 18,
    }),
  ]) {
    batch.set(userRef.collection("quota_snapshots").doc(id), doc, { merge: true });
  }

  for (const [id, doc] of [
    usageDoc({
      id: "review-codex-quota-refresh",
      provider: "codex",
      providerID: "codex",
      accountID: "codex-hosted",
      accountLabel: "Hosted Codex",
      accountSource: "server_private",
      sessionId: "codex-quota-refresh",
      projectName: "Hosted quota sync",
      model: "gpt-5.4-codex",
      inputTokens: 34200,
      outputTokens: 9800,
      cost: 2.84,
      minutes: 16,
      deviceId: "review-ipad-pro",
      deviceName: "Review iPad Pro",
      usageSource: "billing_api",
      provenanceMethod: "billing_api",
    }),
    usageDoc({
      id: "review-claude-mobile-release",
      provider: "claudecode",
      providerID: "claude-code",
      accountID: "claude-local",
      accountLabel: "MacBook Pro",
      accountSource: "local_only",
      sessionId: "claude-code-local-runner",
      projectName: "Mobile release polish",
      model: "claude-sonnet-4.5",
      inputTokens: 51600,
      outputTokens: 14900,
      cacheReadTokens: 8700,
      cost: 3.76,
      minutes: 42,
      deviceId: "review-macbook-pro",
      deviceName: "Review MacBook Pro",
    }),
    usageDoc({
      id: "review-openai-routing-check",
      provider: "openai",
      providerID: "openai",
      accountID: "openai-team",
      accountLabel: "OpenAI Team",
      accountSource: "cloud_refreshable",
      sessionId: "openai-routing-check",
      projectName: "Provider routing",
      model: "gpt-5.4",
      inputTokens: 22400,
      outputTokens: 7100,
      cost: 1.92,
      minutes: 68,
      deviceId: "review-macbook-pro",
      deviceName: "Review MacBook Pro",
      usageSource: "billing_api",
      provenanceMethod: "billing_api",
    }),
  ]) {
    batch.set(userRef.collection("usage").doc(id), doc, { merge: true });
  }

  for (const [id, doc] of [
    rollup("today", { requests: 74, tokens: 412800, costUsd: 18.74, days: 1 }),
    rollup("7d", { requests: 418, tokens: 2814000, costUsd: 126.4, days: 7 }),
    rollup("30d", { requests: 1882, tokens: 13740000, costUsd: 613.92, days: 30 }),
    rollup("90d", { requests: 5264, tokens: 38270000, costUsd: 1719.3, days: 90 }),
    rollup("all_time", { requests: 18921, tokens: 142860000, costUsd: 6284.44, days: 365 }),
  ]) {
    batch.set(userRef.collection("usage_rollups").doc(id), doc, { merge: true });
  }

  batch.set(
    userRef.collection("rollup_jobs").doc("current"),
    { dirty: false, lastComputedAt: iso(now) },
    { merge: true }
  );

  await batch.commit();
}

async function main() {
  const app = admin.initializeApp({ projectId: PROJECT_ID });
  const uid = await upsertReviewUser();
  await seedFirestore(uid);
  console.log(JSON.stringify({ projectId: PROJECT_ID, uid, email: REVIEW_EMAIL }, null, 2));
  await app.delete();
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exitCode = 1;
});
