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

import { AggregateField } from "firebase-admin/firestore";
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

export type DataTier = "ultra" | "pro" | "free";

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
  pensieve: { countCollection: "cloud_search_knowledge", byteCollection: "cloud_search_knowledge", byteField: "byteCount" },
  provider_accounts: { countCollection: "provider_accounts" },
  connected_devices: { countCollection: "devices" },
  external_mcp: { countCollection: "remote_mcp_clients" },
  computer_use: { countCollection: "computer_use_sessions" },
  media: { countCollection: "media_attachment_manifests" },
  entitlements_billing: { countCollection: "entitlements" },
  device_trust_keys: { countCollection: "escrow_devices" },
  audit_timeline: { countCollection: "unified_audit_log" },
};

export async function resolveDataTier(uid: string): Promise<DataTier> {
  const [ultra, proMax] = await Promise.all([
    db.doc(`users/${uid}/entitlements/${BURNBAR_ULTRA_ENTITLEMENT_ID}`).get(),
    db.doc(`users/${uid}/entitlements/${BURNBAR_PRO_MAX_ENTITLEMENT_ID}`).get(),
  ]);
  if (isActiveBurnBarUltraEntitlement(ultra.data())) return "ultra";
  if (isActiveBurnBarCloudProEntitlement(proMax.data())) return "pro";
  return "free";
}

async function domainSnapshot(uid: string, id: string, src: UsageSource): Promise<{ id: string; count: number; bytes: number }> {
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
  { region: "us-central1", enforceAppCheck: getConfig().enforceAppCheck, maxInstances: 50 },
  wrapCallableHandler("getDataDomainUsage", async (request: CallableRequest) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in to view your data usage.");
    enforceAuthAndAppCheck(request, uid);

    const tier = await resolveDataTier(uid);
    const domains = await Promise.all(
      Object.entries(DATA_DOMAIN_USAGE).map(([id, src]) => domainSnapshot(uid, id, src)),
    );

    // Pensieve caps are the only tiered hard limits today; free users see the Pro shape (upsell).
    const pensieveLimits = PENSIEVE_LIMITS[tier === "ultra" ? "ultra" : "pro"];

    return {
      ok: true,
      tier,
      limits: { pensieve: pensieveLimits },
      domains,
      schemaVersion: 1,
    };
  }),
);
