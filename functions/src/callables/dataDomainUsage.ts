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

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db } from "../adminRuntime.js";
import { wrapCallableHandler } from "../logging.js";
import {
  BURNBAR_ULTRA_ENTITLEMENT_ID,
  BURNBAR_PRO_MAX_ENTITLEMENT_ID,
  isActiveBurnBarUltraEntitlement,
  isActiveBurnBarCloudProEntitlement,
} from "./shared.js";
import { PENSIEVE_LIMITS } from "./knowledgeMemory.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

type DataTier = "ultra" | "pro" | "free";
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
  limits: { pensieve: PensieveLimits };
  domains: Array<{ id: string; count: number; bytes: number }>;
  schemaVersion: number;
};

interface UsageSource {
  /** Collection whose docs are counted for the domain footprint. */
  countCollection: string;
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
  session_logs: { countCollection: "cloud_search_documents" },
  pensieve: {
    countCollection: "cloud_search_knowledge",
    byteCollection: "cloud_search_knowledge",
    byteField: "byteCount",
  },
  provider_accounts: { countCollection: "provider_accounts" },
  connected_devices: { countCollection: "devices" },
  external_mcp: { countCollection: "remote_mcp_clients" },
  computer_use: { countCollection: "computer_use_sessions" },
  media: { countCollection: "media_attachment_manifests" },
  entitlements_billing: { countCollection: "entitlements" },
  device_trust_keys: { countCollection: "escrow_devices" },
  audit_timeline: { countCollection: "unified_audit_log" },
};

function optionalString(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function timestampString(value: unknown): string | undefined {
  if (value instanceof Timestamp) return value.toDate().toISOString();
  if (value instanceof Date) return value.toISOString();
  if (
    value &&
    typeof value === "object" &&
    "toDate" in value &&
    typeof (value as { toDate?: unknown }).toDate === "function"
  ) {
    const date = (value as { toDate: () => Date }).toDate();
    return date instanceof Date && !Number.isNaN(date.getTime()) ? date.toISOString() : undefined;
  }
  return optionalString(value);
}

export function summarizeCloudProfile(data: Record<string, unknown> | undefined | null): CloudProfileSummary {
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
  const [ultra, proMax] = await Promise.all([
    db.doc(`users/${uid}/entitlements/${BURNBAR_ULTRA_ENTITLEMENT_ID}`).get(),
    db.doc(`users/${uid}/entitlements/${BURNBAR_PRO_MAX_ENTITLEMENT_ID}`).get(),
  ]);
  if (isActiveBurnBarUltraEntitlement(ultra.data())) return "ultra";
  if (isActiveBurnBarCloudProEntitlement(proMax.data())) return "pro";
  return "free";
}

async function domainSnapshot(
  uid: string,
  id: string,
  src: UsageSource,
): Promise<{ id: string; count: number; bytes: number }> {
  let count = 0;
  let bytes = 0;
  try {
    const agg = await db.collection(`users/${uid}/${src.countCollection}`).count().get();
    count = Number(agg.data().count ?? 0);
  } catch {
    count = 0; // empty/missing collection — fail soft
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
  return { id, count, bytes };
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

    return {
      ok: true,
      tier,
      account: {
        profile,
        hasPublishedData: profile.state === "published" || totals.count > 0 || totals.bytes > 0,
        totalCount: totals.count,
        totalBytes: totals.bytes,
      },
      limits: { pensieve: pensieveLimits },
      domains,
      schemaVersion: 1,
    };
  }),
);
