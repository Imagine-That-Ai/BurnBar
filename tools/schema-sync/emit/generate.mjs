#!/usr/bin/env node
/**
 * Emit Firestore model bindings from tools/schema-sync manifest.
 * Source of truth: TypeSpec domains under typespec/domains/.
 */

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, "..");
const repoRoot = join(root, "..", "..");
const manifest = JSON.parse(readFileSync(join(root, "manifest.json"), "utf8"));

/** Domain field specs — kept in sync with typespec/domains/*.tsp */
const domains = {
  "usage-quota": {
    models: {
      UsageEventDoc: {
        ts: `export interface UsageEventDoc {
  provider: string;
  providerID?: string;
  providerAccountID?: string;
  providerAccountLabel?: string;
  providerAccountSource?: string;
  model?: string;
  sessionId?: string;
  deviceId?: string;
  sourceDeviceId?: string;
  inputTokens?: number;
  outputTokens?: number;
  cacheReadTokens?: number;
  cacheWriteTokens?: number;
  totalTokens?: number;
  costUSD?: number;
  currency?: string;
  recordedAt: string;
  eventKind?: string;
  idempotencyKey?: string;
}`,
        swift: `/// Firestore: users/{uid}/usage/{docId}
public struct FirestoreUsageEventDoc: Codable, Sendable, Equatable {
    public var provider: String
    public var providerID: String?
    public var providerAccountID: String?
    public var providerAccountLabel: String?
    public var providerAccountSource: String?
    public var model: String?
    public var sessionId: String?
    public var deviceId: String?
    public var sourceDeviceId: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?
    public var totalTokens: Int?
    public var costUSD: Double?
    public var currency: String?
    public var recordedAt: String
    public var eventKind: String?
    public var idempotencyKey: String?
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreUsageEventDoc(
    val provider: String = "",
    @get:PropertyName("providerID") @set:PropertyName("providerID")
    var providerId: String? = null,
    @get:PropertyName("providerAccountID") @set:PropertyName("providerAccountID")
    var providerAccountId: String? = null,
    val providerAccountLabel: String? = null,
    val providerAccountSource: String? = null,
    val model: String? = null,
    val sessionId: String? = null,
    val deviceId: String? = null,
    val sourceDeviceId: String? = null,
    val inputTokens: Long? = null,
    val outputTokens: Long? = null,
    val cacheReadTokens: Long? = null,
    val cacheWriteTokens: Long? = null,
    val totalTokens: Long? = null,
    val costUSD: Double? = null,
    val currency: String? = null,
    val recordedAt: String = "",
    val eventKind: String? = null,
    val idempotencyKey: String? = null,
)`,
      },
      QuotaSnapshotDoc: {
        ts: `export interface QuotaSnapshotDoc {
  sourceKind: "provider";
  sourceId: string;
  provider: string;
  providerID?: string;
  accountID?: string;
  accountLabel?: string;
  accountStorageScope?: string;
  fetchedAt: string;
  sourceLabel?: string;
  buckets?: QuotaBucket[];
  resetAt?: string;
  planTier?: string;
}

export interface QuotaBucket {
  name: string;
  used?: number;
  limit?: number;
  unit?: string;
  resetAt?: string;
}`,
        swift: `public struct FirestoreQuotaBucket: Codable, Sendable, Equatable {
    public var name: String
    public var used: Double?
    public var limit: Double?
    public var unit: String?
    public var resetAt: String?
}

/// Firestore: users/{uid}/quota_snapshots/{snapshotId}
public struct FirestoreQuotaSnapshotDoc: Codable, Sendable, Equatable {
    public var sourceKind: String
    public var sourceId: String
    public var provider: String
    public var providerID: String?
    public var accountID: String?
    public var accountLabel: String?
    public var accountStorageScope: String?
    public var fetchedAt: String
    public var sourceLabel: String?
    public var buckets: [FirestoreQuotaBucket]?
    public var resetAt: String?
    public var planTier: String?
}`,
        kotlin: `data class FirestoreQuotaBucket(
    val name: String = "",
    val used: Double? = null,
    val limit: Double? = null,
    val unit: String? = null,
    val resetAt: String? = null,
)

@Keep
@IgnoreExtraProperties
data class FirestoreQuotaSnapshotDoc(
    val sourceKind: String = "provider",
    val sourceId: String = "",
    val provider: String = "",
    @get:PropertyName("providerID") @set:PropertyName("providerID")
    var providerId: String? = null,
    @get:PropertyName("accountID") @set:PropertyName("accountID")
    var accountId: String? = null,
    val accountLabel: String? = null,
    val accountStorageScope: String? = null,
    val fetchedAt: String = "",
    val sourceLabel: String? = null,
    val buckets: List<FirestoreQuotaBucket>? = null,
    val resetAt: String? = null,
    val planTier: String? = null,
)`,
      },
    },
  },
  "provider-account": {
    models: {
      ProviderAccountDoc: {
        ts: `export interface ProviderAccountDoc {
  id: string;
  providerID: string;
  label: string;
  identityHint?: string;
  status: string;
  credentialKind: string;
  storageScope: string;
  redactedLabel: string;
  sourceDeviceID?: string;
  linkedSwitcherProfileID?: string;
  isDefault: boolean;
  sortKey: number;
  lastValidatedAt?: string;
  lastRefreshAt?: string;
  lastErrorCode?: string;
  endpointProfileID?: string;
  region?: "cn" | "sgp" | "ams" | "global";
  tokenPlanTier?: "lite" | "standard" | "pro" | "max";
  tokenPlanBillingCycle?: "monthly" | "annual";
  authMethodID?: string;
  schemaVersion: number;
  createdAt: string;
  updatedAt: string;
}`,
        swift: `/// Firestore: users/{uid}/provider_accounts/{accountID}
public struct FirestoreProviderAccountDoc: Codable, Sendable, Equatable {
    public var id: String
    public var providerID: String
    public var label: String
    public var identityHint: String?
    public var status: String
    public var credentialKind: String
    public var storageScope: String
    public var redactedLabel: String
    public var sourceDeviceID: String?
    public var linkedSwitcherProfileID: String?
    public var isDefault: Bool
    public var sortKey: Int
    public var lastValidatedAt: String?
    public var lastRefreshAt: String?
    public var lastErrorCode: String?
    public var endpointProfileID: String?
    public var region: String?
    public var tokenPlanTier: String?
    public var tokenPlanBillingCycle: String?
    public var authMethodID: String?
    public var schemaVersion: Int
    public var createdAt: String
    public var updatedAt: String
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreProviderAccountDoc(
    val id: String = "",
    @get:PropertyName("providerID") @set:PropertyName("providerID")
    var providerId: String = "",
    val label: String = "",
    val identityHint: String? = null,
    val status: String = "",
    val credentialKind: String = "",
    val storageScope: String = "",
    val redactedLabel: String = "",
    @get:PropertyName("sourceDeviceID") @set:PropertyName("sourceDeviceID")
    var sourceDeviceId: String? = null,
    @get:PropertyName("linkedSwitcherProfileID") @set:PropertyName("linkedSwitcherProfileID")
    var linkedSwitcherProfileId: String? = null,
    @get:PropertyName("isDefault") @set:PropertyName("isDefault")
    var isDefault: Boolean = false,
    val sortKey: Long = 0,
    val lastValidatedAt: String? = null,
    val lastRefreshAt: String? = null,
    val lastErrorCode: String? = null,
    @get:PropertyName("endpointProfileID") @set:PropertyName("endpointProfileID")
    var endpointProfileId: String? = null,
    val region: String? = null,
    val tokenPlanTier: String? = null,
    val tokenPlanBillingCycle: String? = null,
    @get:PropertyName("authMethodID") @set:PropertyName("authMethodID")
    var authMethodId: String? = null,
    val schemaVersion: Long = 0,
    val createdAt: String = "",
    val updatedAt: String = "",
)`,
      },
      ProviderAccountConnectContext: {
        ts: `export interface ProviderAccountConnectContext {
  endpointProfileID?: string;
  region?: "cn" | "sgp" | "ams" | "global";
  tokenPlanTier?: "lite" | "standard" | "pro" | "max";
  tokenPlanBillingCycle?: "monthly" | "annual";
  authMethodID?: string;
}`,
        swift: `public struct FirestoreProviderAccountConnectContext: Codable, Sendable, Equatable {
    public var endpointProfileID: String?
    public var region: String?
    public var tokenPlanTier: String?
    public var tokenPlanBillingCycle: String?
    public var authMethodID: String?
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreProviderAccountConnectContext(
    @get:PropertyName("endpointProfileID") @set:PropertyName("endpointProfileID")
    var endpointProfileId: String? = null,
    val region: String? = null,
    val tokenPlanTier: String? = null,
    val tokenPlanBillingCycle: String? = null,
    @get:PropertyName("authMethodID") @set:PropertyName("authMethodID")
    var authMethodId: String? = null,
)`,
      },
    },
  },
  "hermes-relay": {
    models: {
      HermesRelayRequestDoc: {
        ts: `export interface HermesRelayRequestDoc {
  operation: string;
  status: string;
  sessionId?: string;
  createdAt: string;
  updatedAt?: string;
}`,
        swift: `public struct FirestoreHermesRelayRequestDoc: Codable, Sendable, Equatable {
    public var operation: String
    public var status: String
    public var sessionId: String?
    public var createdAt: String
    public var updatedAt: String?
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreHermesRelayRequestDoc(
    val operation: String = "",
    val status: String = "",
    val sessionId: String? = null,
    val createdAt: String = "",
    val updatedAt: String? = null,
)`,
      },
      HermesRelayChunkDoc: {
        ts: `export interface HermesRelayChunkDoc {
  requestId: string;
  chunkIndex: number;
  payloadBase64: string;
  createdAt: string;
}`,
        swift: `public struct FirestoreHermesRelayChunkDoc: Codable, Sendable, Equatable {
    public var requestId: String
    public var chunkIndex: Int
    public var payloadBase64: String
    public var createdAt: String
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreHermesRelayChunkDoc(
    val requestId: String = "",
    val chunkIndex: Long = 0,
    val payloadBase64: String = "",
    val createdAt: String = "",
)`,
      },
    },
  },
  "iroh-pairing": {
    models: {
      IrohPairingDoc: {
        ts: `export interface IrohPairingDoc {
  pairingCodeDigest: string;
  status: string;
  createdAt: string;
  expiresAt: string;
  platform?: string;
}`,
        swift: `public struct FirestoreIrohPairingDoc: Codable, Sendable, Equatable {
    public var pairingCodeDigest: String
    public var status: String
    public var createdAt: String
    public var expiresAt: String
    public var platform: String?
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreIrohPairingDoc(
    val pairingCodeDigest: String = "",
    val status: String = "",
    val createdAt: String = "",
    val expiresAt: String = "",
    val platform: String? = null,
)`,
      },
    },
  },
  "pi-agent-relay": {
    models: {
      PiAgentConnectionDoc: {
        ts: `export interface PiAgentConnectionDoc {
  mode: string;
  status: string;
  endpointURL?: string;
  createdAt: string;
  updatedAt?: string;
}`,
        swift: `public struct FirestorePiAgentConnectionDoc: Codable, Sendable, Equatable {
    public var mode: String
    public var status: String
    public var endpointURL: String?
    public var createdAt: String
    public var updatedAt: String?
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestorePiAgentConnectionDoc(
    val mode: String = "",
    val status: String = "",
    val endpointURL: String? = null,
    val createdAt: String = "",
    val updatedAt: String? = null,
)`,
      },
    },
  },
  "computer-use": {
    models: {
      ComputerUsePhoneAuthorityDoc: {
        ts: `export interface ComputerUsePhoneAuthorityDoc {
  deviceId: string;
  publicKey: string;
  createdAt: string;
  revokedAt?: string;
}`,
        swift: `public struct FirestoreComputerUsePhoneAuthorityDoc: Codable, Sendable, Equatable {
    public var deviceId: String
    public var publicKey: String
    public var createdAt: String
    public var revokedAt: String?
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreComputerUsePhoneAuthorityDoc(
    val deviceId: String = "",
    val publicKey: String = "",
    val createdAt: String = "",
    val revokedAt: String? = null,
)`,
      },
    },
  },
  "hosted-quota": {
    models: {
      EntitlementBindingDoc: {
        ts: `export interface EntitlementBindingDoc {
  appAccountToken: string;
  uid: string;
  createdAt: string;
}`,
        swift: `public struct FirestoreEntitlementBindingDoc: Codable, Sendable, Equatable {
    public var appAccountToken: String
    public var uid: String
    public var createdAt: String
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreEntitlementBindingDoc(
    val appAccountToken: String = "",
    val uid: String = "",
    val createdAt: String = "",
)`,
      },
    },
  },
  "entitlements": {
    models: {
      EscrowDeviceDoc: {
        ts: `export interface EscrowDeviceDoc {
  deviceId: string;
  trustState: string;
  registeredAt: string;
  approvedAt?: string;
}`,
        swift: `public struct FirestoreEscrowDeviceDoc: Codable, Sendable, Equatable {
    public var deviceId: String
    public var trustState: String
    public var registeredAt: String
    public var approvedAt: String?
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreEscrowDeviceDoc(
    val deviceId: String = "",
    val trustState: String = "",
    val registeredAt: String = "",
    val approvedAt: String? = null,
)`,
      },
    },
  },
  "insights": {
    models: {
      InsightCanvasDoc: {
        ts: `export interface InsightCanvasDoc {
  id: string;
  title: string;
  theme: string;
  origin: string;
  updatedAt: string;
}`,
        swift: `public struct FirestoreInsightCanvasDoc: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var theme: String
    public var origin: String
    public var updatedAt: String
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreInsightCanvasDoc(
    val id: String = "",
    val title: String = "",
    val theme: String = "",
    val origin: String = "",
    val updatedAt: String = "",
)`,
      },
    },
  },
  "missions": {
    models: {
      MissionDispatchDoc: {
        ts: `export interface MissionDispatchDoc {
  missionId: string;
  status: string;
  createdAt: string;
  updatedAt?: string;
  payloadSummary?: string;
}`,
        swift: `public struct FirestoreMissionDispatchDoc: Codable, Sendable, Equatable {
    public var missionId: String
    public var status: String
    public var createdAt: String
    public var updatedAt: String?
    public var payloadSummary: String?
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreMissionDispatchDoc(
    val missionId: String = "",
    val status: String = "",
    val createdAt: String = "",
    val updatedAt: String? = null,
    val payloadSummary: String? = null,
)`,
      },
    },
  },
  "media-analytics": {
    models: {
      MediaQuotaUsageDoc: {
        ts: `export interface MediaQuotaUsageDoc {
  id: string;
  schemaVersion: number;
  bytesUploadedFile: number;
  bytesDownloadedFile: number;
  screenShareSecondsUsed: number;
  videoCallSecondsUsed: number;
}`,
        swift: `public struct FirestoreMediaQuotaUsageDoc: Codable, Sendable, Equatable {
    public var id: String
    public var schemaVersion: Int
    public var bytesUploadedFile: Double
    public var bytesDownloadedFile: Double
    public var screenShareSecondsUsed: Double
    public var videoCallSecondsUsed: Double
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreMediaQuotaUsageDoc(
    val id: String = "",
    val schemaVersion: Long = 0,
    val bytesUploadedFile: Double = 0.0,
    val bytesDownloadedFile: Double = 0.0,
    val screenShareSecondsUsed: Double = 0.0,
    val videoCallSecondsUsed: Double = 0.0,
)`,
      },
    },
  },
};

function emitTypeScript(domainId, models) {
  const header = `// AUTO-GENERATED by tools/schema-sync/emit/generate.mjs — do not edit.
// Domain: ${domainId}
// Regenerate: npm --prefix tools/schema-sync run emit

`;
  return (
    header +
    Object.values(models)
      .map((m) => m.ts)
      .join("\n\n")
  );
}

function emitSwift(domainId, models) {
  const header = `// AUTO-GENERATED by tools/schema-sync/emit/generate.mjs — do not edit.
// Domain: ${domainId}

import Foundation

`;
  return header + Object.values(models).map((m) => m.swift).join("\n\n");
}

function emitKotlin(domainId, models) {
  const header = `// AUTO-GENERATED by tools/schema-sync/emit/generate.mjs — do not edit.
// Domain: ${domainId}

package com.openburnbar.data.models.generated

import androidx.annotation.Keep
import com.google.firebase.firestore.IgnoreExtraProperties
import com.google.firebase.firestore.PropertyName

`;
  return header + Object.values(models).map((m) => m.kotlin).join("\n\n");
}

for (const domain of manifest.domains) {
  const spec = domains[domain.id];
  if (!spec) {
    console.warn(`No emit spec for domain ${domain.id}; skipping`);
    continue;
  }

  const tsPath = join(repoRoot, domain.emit.typescript);
  const swiftPath = join(repoRoot, domain.emit.swift);
  const kotlinPath = join(repoRoot, domain.emit.kotlin);

  for (const path of [tsPath, swiftPath, kotlinPath]) {
    mkdirSync(dirname(path), { recursive: true });
  }

  writeFileSync(tsPath, emitTypeScript(domain.id, spec.models));
  writeFileSync(swiftPath, emitSwift(domain.id, spec.models));
  writeFileSync(kotlinPath, emitKotlin(domain.id, spec.models));
  console.log(`Emitted ${domain.id}: TS, Swift, Kotlin`);
}

console.log("Schema emit complete.");
