import type { Firestore } from "firebase-admin/firestore";
import { computeUserRollups, writeUserRollups } from "./rollups.js";
import type {
  ProviderAccountDoc,
  ProviderAccountStorageScope,
  ProviderID,
  QuotaSnapshotDoc,
  UsageEventDoc,
} from "./types.js";

const DEMO_PREFIX = "demo_android_";
const DEMO_SCHEMA_VERSION = 1;

type DemoProvider = {
  providerID: ProviderID;
  provider: "openai" | "cursor" | "factory" | "codex";
  label: string;
  identityHint: string;
  model: string;
  storageScope: ProviderAccountStorageScope;
  monthlyLimit: number;
  monthlyUsed: number;
  costPerSession: number;
};

type DemoUsageSeed = {
  id: string;
  project: string;
  provider: DemoProvider;
  daysAgo: number;
  hour: number;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  reasoningTokens: number;
};

export type SeedAndroidDemoAccountResult = {
  success: true;
  seeded: true;
  usageCount: number;
  projectCount: number;
  providerAccountCount: number;
  quotaSnapshotCount: number;
  computedAt: string;
};

const DEMO_PROVIDERS: DemoProvider[] = [
  {
    providerID: "codex",
    provider: "codex",
    label: "Codex Pro demo",
    identityHint: "mobile-tester@openburnbar.demo",
    model: "gpt-5.5",
    storageScope: "server_private",
    monthlyLimit: 10_000_000,
    monthlyUsed: 3_180_000,
    costPerSession: 0.82,
  },
  {
    providerID: "cursor",
    provider: "cursor",
    label: "Cursor Team demo",
    identityHint: "cursor-team@openburnbar.demo",
    model: "cursor-agent",
    storageScope: "cloud_refreshable",
    monthlyLimit: 500,
    monthlyUsed: 187,
    costPerSession: 0.46,
  },
  {
    providerID: "openai",
    provider: "openai",
    label: "OpenAI Platform demo",
    identityHint: "platform@openburnbar.demo",
    model: "gpt-5.1",
    storageScope: "cloud_refreshable",
    monthlyLimit: 25_000_000,
    monthlyUsed: 8_900_000,
    costPerSession: 1.08,
  },
  {
    providerID: "factory",
    provider: "factory",
    label: "Factory demo",
    identityHint: "factory@openburnbar.demo",
    model: "factory-droid",
    storageScope: "device_keychain",
    monthlyLimit: 1_000,
    monthlyUsed: 420,
    costPerSession: 0.34,
  },
];

const DEMO_PROJECTS = [
  "BurnBar Android parity",
  "Mac companion sync",
  "Quota cockpit QA",
  "Agent routing experiments",
] as const;

const USAGE_SEEDS: DemoUsageSeed[] = [
  { id: "codex_review_today", project: DEMO_PROJECTS[0], provider: DEMO_PROVIDERS[0], daysAgo: 0, hour: 9, inputTokens: 42_000, outputTokens: 8_400, cacheReadTokens: 6_000, reasoningTokens: 11_000 },
  { id: "cursor_ui_today", project: DEMO_PROJECTS[0], provider: DEMO_PROVIDERS[1], daysAgo: 0, hour: 11, inputTokens: 18_200, outputTokens: 5_100, cacheReadTokens: 1_200, reasoningTokens: 2_000 },
  { id: "openai_insights_today", project: DEMO_PROJECTS[2], provider: DEMO_PROVIDERS[2], daysAgo: 0, hour: 14, inputTokens: 66_500, outputTokens: 9_800, cacheReadTokens: 12_000, reasoningTokens: 4_800 },
  { id: "factory_refactor_yesterday", project: DEMO_PROJECTS[3], provider: DEMO_PROVIDERS[3], daysAgo: 1, hour: 15, inputTokens: 31_000, outputTokens: 7_200, cacheReadTokens: 2_800, reasoningTokens: 6_100 },
  { id: "codex_rollups_yesterday", project: DEMO_PROJECTS[1], provider: DEMO_PROVIDERS[0], daysAgo: 1, hour: 18, inputTokens: 53_500, outputTokens: 12_400, cacheReadTokens: 9_000, reasoningTokens: 18_600 },
  { id: "cursor_nav_2d", project: DEMO_PROJECTS[0], provider: DEMO_PROVIDERS[1], daysAgo: 2, hour: 10, inputTokens: 24_000, outputTokens: 6_800, cacheReadTokens: 3_200, reasoningTokens: 2_900 },
  { id: "openai_docs_3d", project: DEMO_PROJECTS[1], provider: DEMO_PROVIDERS[2], daysAgo: 3, hour: 13, inputTokens: 72_000, outputTokens: 14_000, cacheReadTokens: 18_000, reasoningTokens: 7_200 },
  { id: "factory_qa_5d", project: DEMO_PROJECTS[2], provider: DEMO_PROVIDERS[3], daysAgo: 5, hour: 16, inputTokens: 38_000, outputTokens: 9_100, cacheReadTokens: 2_200, reasoningTokens: 5_000 },
  { id: "codex_release_8d", project: DEMO_PROJECTS[0], provider: DEMO_PROVIDERS[0], daysAgo: 8, hour: 12, inputTokens: 91_000, outputTokens: 20_400, cacheReadTokens: 22_000, reasoningTokens: 26_000 },
  { id: "openai_billing_13d", project: DEMO_PROJECTS[2], provider: DEMO_PROVIDERS[2], daysAgo: 13, hour: 17, inputTokens: 44_000, outputTokens: 8_900, cacheReadTokens: 5_300, reasoningTokens: 3_000 },
  { id: "cursor_widgets_21d", project: DEMO_PROJECTS[3], provider: DEMO_PROVIDERS[1], daysAgo: 21, hour: 11, inputTokens: 28_000, outputTokens: 7_600, cacheReadTokens: 2_700, reasoningTokens: 3_400 },
  { id: "codex_archive_34d", project: DEMO_PROJECTS[1], provider: DEMO_PROVIDERS[0], daysAgo: 34, hour: 10, inputTokens: 47_000, outputTokens: 10_500, cacheReadTokens: 8_300, reasoningTokens: 12_700 },
];

function isoAt(now: Date, daysAgo: number, hour: number): string {
  const date = new Date(Date.UTC(
    now.getUTCFullYear(),
    now.getUTCMonth(),
    now.getUTCDate() - daysAgo,
    hour,
    30,
    0,
    0
  ));
  return date.toISOString();
}

function demoAccount(provider: DemoProvider, nowISO: string): ProviderAccountDoc {
  const id = `${DEMO_PREFIX}${provider.providerID}`;
  return {
    id,
    providerID: provider.providerID,
    label: provider.label,
    identityHint: provider.identityHint,
    status: "connected",
    credentialKind: provider.provider === "codex" ? "plan" : "token",
    storageScope: provider.storageScope,
    redactedLabel: `${provider.providerID}_***demo`,
    sourceDeviceID: `${DEMO_PREFIX}pixel`,
    isDefault: provider.provider === "codex",
    sortKey: DEMO_PROVIDERS.findIndex((entry) => entry.providerID === provider.providerID),
    lastValidatedAt: nowISO,
    lastRefreshAt: nowISO,
    schemaVersion: DEMO_SCHEMA_VERSION,
    createdAt: nowISO,
    updatedAt: nowISO,
  };
}

function demoQuotaSnapshot(provider: DemoProvider, nowISO: string): QuotaSnapshotDoc {
  const accountID = `${DEMO_PREFIX}${provider.providerID}`;
  const remaining = Math.max(provider.monthlyLimit - provider.monthlyUsed, 0);
  return {
    sourceKind: "provider",
    sourceId: accountID,
    provider: provider.provider,
    providerID: provider.providerID,
    accountID,
    accountLabel: provider.label,
    accountStorageScope: provider.storageScope,
    fetchedAt: nowISO,
    source: "Demo data",
    confidence: "high",
    statusMessage: "Seeded demo quota for Android closed testing.",
    buckets: [
      {
        name: provider.provider === "cursor" || provider.provider === "factory" ? "requests" : "tokens",
        used: provider.monthlyUsed,
        limit: provider.monthlyLimit,
        remaining,
        window: "monthly",
        meta: { demo: true },
      },
    ],
    schemaVersion: DEMO_SCHEMA_VERSION,
    updatedAt: nowISO,
  };
}

function demoUsage(seed: DemoUsageSeed, now: Date): UsageEventDoc & Record<string, unknown> {
  const startTime = isoAt(now, seed.daysAgo, seed.hour);
  const endTime = new Date(new Date(startTime).getTime() + 11 * 60 * 1000).toISOString();
  const totalTokens =
    seed.inputTokens +
    seed.outputTokens +
    seed.cacheReadTokens +
    seed.reasoningTokens;
  const costUsd = Number(
    (seed.provider.costPerSession * (0.72 + totalTokens / 150_000)).toFixed(6)
  );
  return {
    provider: seed.provider.provider,
    providerID: seed.provider.providerID,
    providerAccountID: `${DEMO_PREFIX}${seed.provider.providerID}`,
    providerAccountLabel: seed.provider.label,
    providerAccountSource: seed.provider.storageScope,
    model: seed.provider.model,
    sessionId: `${DEMO_PREFIX}${seed.id}`,
    deviceId: `${DEMO_PREFIX}pixel`,
    sourceDeviceId: `${DEMO_PREFIX}macbook`,
    inputTokens: seed.inputTokens,
    outputTokens: seed.outputTokens,
    cacheReadTokens: seed.cacheReadTokens,
    reasoningTokens: seed.reasoningTokens,
    totalTokens,
    costUsd,
    cost: costUsd,
    provenanceConfidence: "exact",
    provenanceMethod: "android_demo_seed",
    timestamp: startTime,
    startTime,
    endTime,
    createdAt: startTime,
    updatedAt: endTime,
    schemaVersion: DEMO_SCHEMA_VERSION,
    demo: true,
    project_name: seed.project,
    projectName: seed.project,
    user_display_id: "Android closed tester",
  };
}

function projectSummaries(usages: Array<UsageEventDoc & Record<string, unknown>>): Array<{
  id: string;
  data: Record<string, unknown>;
}> {
  const summaries = new Map<string, { totalCost: number; totalTokens: number; totalSessions: number }>();
  for (const usage of usages) {
    const name = String(usage.project_name ?? "Demo project");
    const current = summaries.get(name) ?? { totalCost: 0, totalTokens: 0, totalSessions: 0 };
    current.totalCost += typeof usage.costUsd === "number" ? usage.costUsd : 0;
    current.totalTokens += typeof usage.totalTokens === "number" ? usage.totalTokens : 0;
    current.totalSessions += 1;
    summaries.set(name, current);
  }
  return [...summaries.entries()].map(([name, summary]) => ({
    id: `${DEMO_PREFIX}${name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "")}`,
    data: {
      name,
      total_cost: Number(summary.totalCost.toFixed(6)),
      total_tokens: summary.totalTokens,
      total_sessions: summary.totalSessions,
      demo: true,
      schemaVersion: DEMO_SCHEMA_VERSION,
    },
  }));
}

async function deleteDemoDocs(
  db: Firestore,
  uid: string,
  collectionName: string
): Promise<number> {
  const snapshot = await db.collection(`users/${uid}/${collectionName}`).get();
  const refs = snapshot.docs
    .filter((doc) => doc.id.startsWith(DEMO_PREFIX) || doc.get("demo") === true)
    .map((doc) => doc.ref);
  if (refs.length === 0) return 0;

  let deleted = 0;
  for (let index = 0; index < refs.length; index += 450) {
    const batch = db.batch();
    for (const ref of refs.slice(index, index + 450)) {
      batch.delete(ref);
      deleted += 1;
    }
    await batch.commit();
  }
  return deleted;
}

export async function seedAndroidDemoAccount(
  db: Firestore,
  uid: string,
  now: Date = new Date()
): Promise<SeedAndroidDemoAccountResult> {
  await Promise.all([
    deleteDemoDocs(db, uid, "usage"),
    deleteDemoDocs(db, uid, "projects"),
    deleteDemoDocs(db, uid, "provider_accounts"),
    deleteDemoDocs(db, uid, "quota_snapshots"),
  ]);

  const nowISO = now.toISOString();
  const usages = USAGE_SEEDS.map((seed) => ({
    id: `${DEMO_PREFIX}${seed.id}`,
    data: demoUsage(seed, now),
  }));
  const projects = projectSummaries(usages.map((entry) => entry.data));
  const accounts = DEMO_PROVIDERS.map((provider) => ({
    id: `${DEMO_PREFIX}${provider.providerID}`,
    data: { ...demoAccount(provider, nowISO), demo: true },
  }));
  const quotas = DEMO_PROVIDERS.map((provider) => ({
    id: `${DEMO_PREFIX}${provider.providerID}`,
    data: { ...demoQuotaSnapshot(provider, nowISO), demo: true },
  }));

  const batch = db.batch();
  for (const usage of usages) {
    batch.set(db.doc(`users/${uid}/usage/${usage.id}`), usage.data, { merge: false });
  }
  for (const project of projects) {
    batch.set(db.doc(`users/${uid}/projects/${project.id}`), project.data, { merge: false });
  }
  for (const account of accounts) {
    batch.set(db.doc(`users/${uid}/provider_accounts/${account.id}`), account.data, { merge: false });
  }
  for (const quota of quotas) {
    batch.set(db.doc(`users/${uid}/quota_snapshots/${quota.id}`), quota.data, { merge: false });
  }
  await batch.commit();

  const rollups = await computeUserRollups(db, uid);
  await writeUserRollups(db, uid, rollups);

  return {
    success: true,
    seeded: true,
    usageCount: usages.length,
    projectCount: projects.length,
    providerAccountCount: accounts.length,
    quotaSnapshotCount: quotas.length,
    computedAt: rollups.all_time.computedAt,
  };
}
