/**
 * @fileoverview getDataDomainUsage — read-only usage snapshot for the Data &
 * Privacy Control Center.
 *
 * Returns the member's tier, the canonical Pensieve limits, and a per-domain
 * {count, bytes} snapshot so every client (web, iOS, iPadOS, macOS, Android)
 * renders the control center without duplicating server constants (no drift).
 * Fail-soft: a domain whose collection is empty/missing reports 0 rather than
 * failing the whole dashboard.
 *
 * The DATA_DOMAIN_USAGE map is the server-authoritative count/byte source per
 * domain; a unit test asserts its ids match the canonical packages/data-domains
 * registry, so the two never drift.
 */

import { AggregateField, Timestamp } from "firebase-admin/firestore";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";
import { WAND_PARALLEL_CAPS } from "@openburnbar/entitlements";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db } from "../adminRuntime.js";
import { wrapCallableHandler } from "../logging.js";
import {
  BURNBAR_PRO_ENTITLEMENT_ID,
  BURNBAR_ULTRA_ENTITLEMENT_ID,
  BURNBAR_PRO_MAX_ENTITLEMENT_ID,
  isActiveHostedQuotaEntitlement,
  isActivePremiumEntitlement,
  isActiveBurnBarUltraEntitlement,
  isActiveBurnBarCloudProEntitlement,
} from "./shared.js";
import { PENSIEVE_LIMITS } from "./knowledgeMemory.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

type DataTier = "ultra" | "pro" | "cloud" | "free";

const HOSTED_QUOTA_SYNC_ENTITLEMENT_ID = "hosted_quota_sync";

export function wandParallelMaxForDataTier(tier: DataTier): number {
  return WAND_PARALLEL_CAPS[tier];
}

export function resolveDataTierFromEntitlements(raw: {
  ultra?: Record<string, unknown> | null;
  cloudPro?: Record<string, unknown> | null;
  cloud?: Record<string, unknown> | null;
  legacyCloud?: Record<string, unknown> | null;
}): DataTier {
  if (isActiveBurnBarUltraEntitlement(raw.ultra ?? undefined)) {
    return "ultra";
  }
  if (isActiveBurnBarCloudProEntitlement(raw.cloudPro ?? undefined)) {
    return "pro";
  }
  if (
    isActiveHostedQuotaEntitlement(raw.cloud ?? undefined) ||
    isActivePremiumEntitlement(raw.legacyCloud ?? undefined)
  ) {
    return "cloud";
  }
  return "free";
}
type CloudProfileState = "published" | "missing";

interface CloudProfileSummary {
  state: CloudProfileState;
  displayName?: string;
  avatarURL?: string;
  sourceDeviceId?: string;
  updatedAt?: string;
}

type PensieveLimits = { sources: number; chunks: number; bytes: number };

type DataDomainUsageResponse = {
  ok: true;
  tier: DataTier;
  account: {
    profile: CloudProfileSummary;
    hasPublishedData: boolean;
    totalCount: number;
    totalBytes: number;
  };
  limits: { pensieve: PensieveLimits; wandParallelMax: number };
  /**
   * Per-domain footprint. `countable: false` means this domain HAS no per-user
   * count to report, which is not "zero documents" (PR 4 review L7): `count`
   * stays 0 so older clients keep parsing, and a client that understands the
   * marker renders "not counted here" instead of a number it would be inventing.
   */
  domains: Array<{ id: string; count: number; bytes: number; countable: boolean }>;
  schemaVersion: number;
};

interface UsageSource {
  /**
   * Collection whose docs are counted for the domain footprint.
   *
   * ABSENT means "this domain has no per-user footprint to count", which is not
   * the same as "zero documents". Team memory (`team_pensieve`) is the case:
   * its documents live in a SHARED tenant at `team_memory_facts/{teamId}/facts`,
   * not under `users/{uid}/`, so there is no per-user collection to aggregate
   * and counting one would be inventing a number.
   */
  countCollection?: string;
  /** Optional numeric field summed across the collection for a byte total. */
  byteCollection?: string;
  byteField?: string;
}

/**
 * Server-authoritative per-domain usage sources. Ids MUST match the canonical
 * registry (packages/data-domains/registry.json) — enforced by the unit test.
 */
export const DATA_DOMAIN_USAGE: Record<string, UsageSource> = {
  usage_spend: { countCollection: "usage" },
  conversations_chat: { countCollection: "chat_threads" },
  session_logs: {
    countCollection: "cloud_search_documents",
    byteCollection: "cloud_search_documents",
    byteField: "byteCount",
  },
  pensieve: {
    countCollection: "cloud_search_knowledge",
    byteCollection: "cloud_search_knowledge",
    byteField: "byteCount",
  },
  provider_accounts: { countCollection: "provider_accounts" },
  connected_devices: { countCollection: "devices" },
  external_mcp: { countCollection: "remote_mcp_clients" },
  computer_use: { countCollection: "computer_use_sessions" },
  media: {
    countCollection: "media_attachment_manifests",
    byteCollection: "media_attachment_manifests",
    byteField: "size",
  },
  entitlements_billing: { countCollection: "entitlements" },
  device_trust_keys: { countCollection: "escrow_devices" },
  audit_timeline: { countCollection: "unified_audit_log" },
  // No per-user count source: team facts are a shared tenant (see UsageSource).
  team_pensieve: {},
};

function optionalString(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function timestampString(value: unknown): string | undefined {
  if (value instanceof Timestamp) return value.toDate().toISOString();
  if (value instanceof Date) return value.toISOString();
  const toDate = value && typeof value === "object" ? Reflect.get(value, "toDate") : undefined;
  if (typeof toDate === "function") {
    const date = toDate.call(value);
    return date instanceof Date && !Number.isNaN(date.getTime()) ? date.toISOString() : undefined;
  }
  return optionalString(value);
}

function summarizeCloudProfile(data: Record<string, unknown> | undefined | null): CloudProfileSummary {
  if (!data) return { state: "missing" };

  return {
    state: "published",
    displayName: optionalString(data.displayName),
    avatarURL: optionalString(data.avatarURL),
    sourceDeviceId: optionalString(data.sourceDeviceId),
    updatedAt: timestampString(data.updatedAt),
  };
}

async function cloudProfileSnapshot(uid: string): Promise<CloudProfileSummary> {
  const snap = await db.doc(`users/${uid}/cloud_profile/default`).get();
  return summarizeCloudProfile(snap.exists ? snap.data() : undefined);
}

async function resolveDataTier(uid: string): Promise<DataTier> {
  const [ultra, proMax, cloud, legacyCloud] = await Promise.all([
    db.doc(`users/${uid}/entitlements/${BURNBAR_ULTRA_ENTITLEMENT_ID}`).get(),
    db.doc(`users/${uid}/entitlements/${BURNBAR_PRO_MAX_ENTITLEMENT_ID}`).get(),
    db.doc(`users/${uid}/entitlements/${HOSTED_QUOTA_SYNC_ENTITLEMENT_ID}`).get(),
    db.doc(`users/${uid}/entitlements/${BURNBAR_PRO_ENTITLEMENT_ID}`).get(),
  ]);
  return resolveDataTierFromEntitlements({
    ultra: ultra.data(),
    cloudPro: proMax.data(),
    cloud: cloud.data(),
    legacyCloud: legacyCloud.data(),
  });
}

async function domainSnapshot(
  uid: string,
  id: string,
  src: UsageSource,
): Promise<{ id: string; count: number; bytes: number; countable: boolean }> {
  let count = 0;
  let bytes = 0;
  if (src.countCollection) {
    try {
      const agg = await db.collection(`users/${uid}/${src.countCollection}`).count().get();
      count = Number(agg.data().count ?? 0);
    } catch {
      count = 0; // empty/missing collection — fail soft
    }
  }
  if (src.byteCollection && src.byteField) {
    try {
      const agg = await db
        .collection(`users/${uid}/${src.byteCollection}`)
        .aggregate({ b: AggregateField.sum(src.byteField) })
        .get();
      bytes = Number(agg.data().b ?? 0);
    } catch {
      bytes = 0;
    }
  }
  // `countable` is derived from the SOURCE, never from the result: a domain with
  // a count collection that happens to be empty is countable and reports 0; a
  // domain with no count collection reports "not countable" and its 0 means
  // nothing (PR 4 review L7).
  return { id, count, bytes, countable: src.countCollection !== undefined };
}

export const getDataDomainUsage = onCall(
  { region: FUNCTIONS_REGION, enforceAppCheck: getConfig().enforceAppCheck, maxInstances: 50 },
  wrapCallableHandler("getDataDomainUsage", async (request: CallableRequest): Promise<DataDomainUsageResponse> => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in to view your data usage.");
    enforceAuthAndAppCheck(request, uid);

    const [tier, profile] = await Promise.all([resolveDataTier(uid), cloudProfileSnapshot(uid)]);
    const domains = await Promise.all(
      Object.entries(DATA_DOMAIN_USAGE).map(([id, src]) => domainSnapshot(uid, id, src)),
    );
    const totals = domains.reduce(
      (acc, domain) => ({
        count: acc.count + domain.count,
        bytes: acc.bytes + domain.bytes,
      }),
      { count: 0, bytes: 0 },
    );

    // Pensieve caps are the only tiered hard limits today; free users see the Pro shape (upsell).
    const pensieveLimits = PENSIEVE_LIMITS[tier === "ultra" ? "ultra" : "pro"];
    const wandParallelMax = wandParallelMaxForDataTier(tier);

    return {
      ok: true,
      tier,
      account: {
        profile,
        hasPublishedData: profile.state === "published" || totals.count > 0 || totals.bytes > 0,
        totalCount: totals.count,
        totalBytes: totals.bytes,
      },
      limits: { pensieve: pensieveLimits, wandParallelMax },
      domains,
      schemaVersion: 1,
    };
  }),
);
