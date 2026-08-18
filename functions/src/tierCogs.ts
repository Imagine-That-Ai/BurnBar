/**
 * @fileoverview Per-tier daily COGS monitor for commercial launch readiness.
 */

import { Timestamp, getFirestore } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";

import { isRecord, numberField } from "./guards.js";
import { FUNCTIONS_REGION } from "./runtimeOptions.js";

const CLOUD_ENTITLEMENT_ID = "burnbar_pro";
const CLOUD_PRO_ENTITLEMENT_ID = "burnbar_pro_max";
const MEDIA_COST_PER_GB_USD = 0.04;
const CLOUD_DAILY_BASE_COGS_USD = 0.24 / 30;
const CLOUD_MONTHLY_PRICE_USD = 7.99;
const CLOUD_PRO_MONTHLY_PRICE_USD = 24.99;
const STORE_NET_REVENUE_FACTOR = 0.85;

export const TIER_COGS_UNIT_COSTS = {
  quotaRefreshUSD: 0.00010998,
  indexedSessionUSD: 0.0001172,
  searchUSD: 0.000083,
  hostedInsightUSD: 0.0015,
  remoteMcpGrantUSD: 0.00002,
  usageEventUSD: 0.00002,
  mediaRelayHourUSD: 0.054,
  mediaRelayGBUSD: MEDIA_COST_PER_GB_USD,
  hostedVisionActionUSD: 0.013,
};

interface TierInputs {
  activeSubscribers: number;
  dailyBaseCogsUSD: number;
  mediaRelayCogsUSD?: number;
  hostedVisionCogsUSD?: number;
  hostedInsightsCogsUSD?: number;
  netRevenuePerSubscriberDayUSD: number;
}

interface TierCogsDailyInput {
  dayKey: string;
  cloud: TierInputs;
  cloudPro: TierInputs;
}

interface TierCogsBucket {
  activeSubscribers: number;
  netRevenueUSD: number;
  cogsUSD: number;
  grossMarginUSD: number;
  grossMarginRatio: number | null;
}

interface TierCogsDailyDoc {
  id: string;
  dayKey: string;
  unitCosts: typeof TIER_COGS_UNIT_COSTS;
  cloud: TierCogsBucket;
  cloudPro: TierCogsBucket;
  mediaRelayCogsUSD: number;
  hostedVisionCogsUSD: number;
  hostedInsightsCogsUSD: number;
  updatedAt: Timestamp;
  schemaVersion: 1;
}

function money(value: number): number {
  return Math.round(value * 10000) / 10000;
}

function grossMarginRatio(revenue: number, cogs: number): number | null {
  if (revenue <= 0) return null;
  return money((revenue - cogs) / revenue);
}

function buildBucket(input: TierInputs): TierCogsBucket {
  const netRevenueUSD = money(input.activeSubscribers * input.netRevenuePerSubscriberDayUSD);
  const cogsUSD = money(
    input.activeSubscribers * input.dailyBaseCogsUSD +
      (input.mediaRelayCogsUSD ?? 0) +
      (input.hostedVisionCogsUSD ?? 0) +
      (input.hostedInsightsCogsUSD ?? 0),
  );
  return {
    activeSubscribers: input.activeSubscribers,
    netRevenueUSD,
    cogsUSD,
    grossMarginUSD: money(netRevenueUSD - cogsUSD),
    grossMarginRatio: grossMarginRatio(netRevenueUSD, cogsUSD),
  };
}

export function buildTierCogsDailyDoc(input: TierCogsDailyInput, updatedAt: Timestamp): TierCogsDailyDoc {
  return {
    id: input.dayKey,
    dayKey: input.dayKey,
    unitCosts: TIER_COGS_UNIT_COSTS,
    cloud: buildBucket(input.cloud),
    cloudPro: buildBucket(input.cloudPro),
    mediaRelayCogsUSD: money(input.cloudPro.mediaRelayCogsUSD ?? 0),
    hostedVisionCogsUSD: money(input.cloudPro.hostedVisionCogsUSD ?? 0),
    hostedInsightsCogsUSD: money(input.cloud.hostedInsightsCogsUSD ?? 0),
    updatedAt,
    schemaVersion: 1,
  };
}

export function tierCogsDailyDocPath(dayKey: string): string {
  return `ops/cogs_by_tier/days/${dayKey}`;
}

function previousUtcDay(now: Date): string {
  const today = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  return new Date(today - 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
}

async function countActiveEntitlements(entitlementID: string): Promise<number> {
  const snap = await getFirestore()
    .collectionGroup("entitlements")
    .where("id", "==", entitlementID)
    .where("active", "==", true)
    .count()
    .get();
  return snap.data().count;
}

async function mediaRelayCogsForDay(dayKey: string): Promise<number> {
  const snap = await getFirestore().doc(`ops/media_session_daily_rollups/days/${dayKey}`).get();
  const data = snap.data();
  const perFeature = data?.perFeature;
  if (!isRecord(perFeature)) return 0;
  let totalBytes = 0;
  for (const feature of ["fileTransfer", "screenShare", "videoCall"]) {
    const bucket = perFeature[feature];
    if (isRecord(bucket)) {
      totalBytes += numberField(bucket, "totalBytes") ?? 0;
    }
  }
  return (totalBytes / 1_000_000_000) * MEDIA_COST_PER_GB_USD;
}

async function hostedVisionCogsForDay(dayKey: string): Promise<number> {
  const snap = await getFirestore().doc(`ops/computer_use_session_daily_rollups/days/${dayKey}`).get();
  return numberField(snap.data(), "visionModelSpendUSD") ?? 0;
}

/**
 * Owner-funded OpenRouter spend from `insightsHostedAnswer`, written per day by
 * the callable itself. Before this line existed the margin dashboard was blind
 * to the one hosted path where BurnBar pays for inference directly.
 */
async function hostedInsightsCogsForDay(dayKey: string): Promise<number> {
  const snap = await getFirestore().doc(`ops/hosted_insights_daily_rollups/days/${dayKey}`).get();
  return numberField(snap.data(), "spendUSD") ?? 0;
}

export const computeTierCogsDaily = onSchedule(
  {
    schedule: "15 1 * * *",
    timeZone: "UTC",
    region: FUNCTIONS_REGION,
    timeoutSeconds: 540,
  },
  async () => {
    const dayKey = previousUtcDay(new Date());
    const [cloudSubscribers, cloudProSubscribers, mediaRelayCogsUSD, hostedVisionCogsUSD, hostedInsightsCogsUSD] =
      await Promise.all([
        countActiveEntitlements(CLOUD_ENTITLEMENT_ID),
        countActiveEntitlements(CLOUD_PRO_ENTITLEMENT_ID),
        mediaRelayCogsForDay(dayKey),
        hostedVisionCogsForDay(dayKey),
        hostedInsightsCogsForDay(dayKey),
      ]);

    const doc = buildTierCogsDailyDoc(
      {
        dayKey,
        cloud: {
          activeSubscribers: cloudSubscribers,
          dailyBaseCogsUSD: CLOUD_DAILY_BASE_COGS_USD,
          // Hosted answers are gated on the Cloud (`burnbar_pro`) entitlement,
          // so their inference spend is a Cloud-tier COGS line.
          hostedInsightsCogsUSD,
          netRevenuePerSubscriberDayUSD: (CLOUD_MONTHLY_PRICE_USD * STORE_NET_REVENUE_FACTOR) / 30,
        },
        cloudPro: {
          activeSubscribers: cloudProSubscribers,
          dailyBaseCogsUSD: CLOUD_DAILY_BASE_COGS_USD,
          mediaRelayCogsUSD,
          hostedVisionCogsUSD,
          netRevenuePerSubscriberDayUSD: (CLOUD_PRO_MONTHLY_PRICE_USD * STORE_NET_REVENUE_FACTOR) / 30,
        },
      },
      Timestamp.now(),
    );

    await getFirestore().doc(tierCogsDailyDocPath(dayKey)).set(doc, { merge: true });
  },
);
