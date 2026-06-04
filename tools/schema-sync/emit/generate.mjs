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
  "hermes-gateway": {
    models: {
      HermesGatewayModelOptionDoc: {
        ts: `export interface HermesGatewayModelOptionDoc {
  providerId: string;
  providerName: string;
  modelId: string;
  displayName: string;
}`,
        swift: `public struct FirestoreHermesGatewayModelOptionDoc: Codable, Sendable, Equatable {
    public var providerId: String
    public var providerName: String
    public var modelId: String
    public var displayName: String
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreHermesGatewayModelOptionDoc(
    val providerId: String = "",
    val providerName: String = "",
    val modelId: String = "",
    val displayName: String = "",
)`,
      },
      GatewayRelayEnvelopeDoc: {
        ts: `export interface GatewayRelayEnvelopeDoc {
  payloadCiphertext: string;
  wrappedKey: string;
  relayEncryption: string;
  relayKeyVersion: number;
  enc?: string;
  senderPublicKey?: string;
}`,
        swift: `public struct FirestoreGatewayRelayEnvelopeDoc: Codable, Sendable, Equatable {
    public var payloadCiphertext: String
    public var wrappedKey: String
    public var relayEncryption: String
    public var relayKeyVersion: Int
    public var enc: String?
    public var senderPublicKey: String?
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreGatewayRelayEnvelopeDoc(
    val payloadCiphertext: String = "",
    val wrappedKey: String = "",
    val relayEncryption: String = "",
    val relayKeyVersion: Long = 0,
    val enc: String? = null,
    val senderPublicKey: String? = null,
)`,
      },
      GatewayRatchetHeaderDoc: {
        ts: `export interface GatewayRatchetHeaderDoc {
  version: number;
  algorithm: string;
  sessionID: string;
  senderDeviceID: string;
  receiverDeviceID: string;
  ratchetPublicKeyBase64: string;
  previousChainLength: number;
  messageNumber: number;
  epoch: number;
}`,
        swift: `public struct FirestoreGatewayRatchetHeaderDoc: Codable, Sendable, Equatable {
    public var version: Int
    public var algorithm: String
    public var sessionID: String
    public var senderDeviceID: String
    public var receiverDeviceID: String
    public var ratchetPublicKeyBase64: String
    public var previousChainLength: Int
    public var messageNumber: Int
    public var epoch: Int
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreGatewayRatchetHeaderDoc(
    val version: Long = 0,
    @get:PropertyName("sessionID") @set:PropertyName("sessionID")
    var sessionId: String = "",
    @get:PropertyName("senderDeviceID") @set:PropertyName("senderDeviceID")
    var senderDeviceId: String = "",
    @get:PropertyName("receiverDeviceID") @set:PropertyName("receiverDeviceID")
    var receiverDeviceId: String = "",
    val algorithm: String = "",
    val ratchetPublicKeyBase64: String = "",
    val previousChainLength: Long = 0,
    val messageNumber: Long = 0,
    val epoch: Long = 0,
)`,
      },
      GatewayRatchetEnvelopeDoc: {
        ts: `export interface GatewayRatchetEnvelopeDoc {
  header: GatewayRatchetHeaderDoc;
  ciphertextBase64: string;
}`,
        swift: `public struct FirestoreGatewayRatchetEnvelopeDoc: Codable, Sendable, Equatable {
    public var header: FirestoreGatewayRatchetHeaderDoc
    public var ciphertextBase64: String
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreGatewayRatchetEnvelopeDoc(
    val header: FirestoreGatewayRatchetHeaderDoc = FirestoreGatewayRatchetHeaderDoc(),
    val ciphertextBase64: String = "",
)`,
      },
      HermesGatewayClientDoc: {
        ts: `export interface HermesGatewayClientDoc {
  id: string;
  uid: string;
  displayName: string;
  status: string;
  tokenHash: string;
  tokenPreview: string;
  scopes: string[];
  homeDestinationId: string;
  lastSeenAt?: string;
  runtimeModelId?: string;
  runtimeProviderId?: string;
  runtimeModelOptions?: HermesGatewayModelOptionDoc[];
  runtimeUpdatedAt?: string;
  agentVersion?: string;
  pendingModelId?: string;
  pendingModelRequestedAt?: string;
  oversightMode?: string;
  relayPublicKey?: string;
  relayKeyVersion?: number;
  relayEncryption?: string;
  agentRelayPublicKey?: string;
  agentRelayKeyVersion?: number;
  agentRelayEncryption?: string;
  agentSupportsRelayEnvelopeVersions?: number[];
  agentPreferredRelayEnvelopeVersion?: number;
  agentSupportsHpkeV3?: boolean;
  agentPlatform?: string;
  agentAppBuild?: string;
  phoneRelayPublicKey?: string;
  phoneRelayKeyVersion?: number;
  phoneRelayEncryption?: string;
  phoneSupportsRelayEnvelopeVersions?: number[];
  phonePreferredRelayEnvelopeVersion?: number;
  phoneSupportsHpkeV3?: boolean;
  phonePlatform?: string;
  phoneAppBuild?: string;
  agentRatchetIdentityPublicKey?: string;
  agentRatchetSigningPublicKey?: string;
  agentRatchetSignedPreKeyPublicKey?: string;
  agentRatchetSignedPreKeyId?: string;
  agentRatchetSignedPreKeySignature?: string;
  agentSupportsRatchetV1?: boolean;
  phoneRatchetIdentityPublicKey?: string;
  phoneRatchetSigningPublicKey?: string;
  phoneRatchetSignedPreKeyPublicKey?: string;
  phoneRatchetSignedPreKeyId?: string;
  phoneRatchetSignedPreKeySignature?: string;
  phoneSupportsRatchetV1?: boolean;
  supportsRatchetV1?: boolean;
  supportsRelayEnvelopeVersions?: number[];
  preferredRelayEnvelopeVersion?: number;
  supportsHpkeV3?: boolean;
  relayCapable?: boolean;
  revokedAt?: string;
  createdAt: string;
  updatedAt: string;
  schemaVersion: number;
}`,
        swift: `public struct FirestoreHermesGatewayClientDoc: Codable, Sendable, Equatable {
    public var id: String
    public var uid: String
    public var displayName: String
    public var status: String
    public var tokenHash: String
    public var tokenPreview: String
    public var scopes: [String]
    public var homeDestinationId: String
    public var lastSeenAt: String?
    public var runtimeModelId: String?
    public var runtimeProviderId: String?
    public var runtimeModelOptions: [FirestoreHermesGatewayModelOptionDoc]?
    public var runtimeUpdatedAt: String?
    public var agentVersion: String?
    public var pendingModelId: String?
    public var pendingModelRequestedAt: String?
    public var oversightMode: String?
    public var relayPublicKey: String?
    public var relayKeyVersion: Int?
    public var relayEncryption: String?
    public var agentRelayPublicKey: String?
    public var agentRelayKeyVersion: Int?
    public var agentRelayEncryption: String?
    public var agentSupportsRelayEnvelopeVersions: [Int]?
    public var agentPreferredRelayEnvelopeVersion: Int?
    public var agentSupportsHpkeV3: Bool?
    public var agentPlatform: String?
    public var agentAppBuild: String?
    public var phoneRelayPublicKey: String?
    public var phoneRelayKeyVersion: Int?
    public var phoneRelayEncryption: String?
    public var phoneSupportsRelayEnvelopeVersions: [Int]?
    public var phonePreferredRelayEnvelopeVersion: Int?
    public var phoneSupportsHpkeV3: Bool?
    public var phonePlatform: String?
    public var phoneAppBuild: String?
    public var agentRatchetIdentityPublicKey: String?
    public var agentRatchetSigningPublicKey: String?
    public var agentRatchetSignedPreKeyPublicKey: String?
    public var agentRatchetSignedPreKeyId: String?
    public var agentRatchetSignedPreKeySignature: String?
    public var agentSupportsRatchetV1: Bool?
    public var phoneRatchetIdentityPublicKey: String?
    public var phoneRatchetSigningPublicKey: String?
    public var phoneRatchetSignedPreKeyPublicKey: String?
    public var phoneRatchetSignedPreKeyId: String?
    public var phoneRatchetSignedPreKeySignature: String?
    public var phoneSupportsRatchetV1: Bool?
    public var supportsRatchetV1: Bool?
    public var supportsRelayEnvelopeVersions: [Int]?
    public var preferredRelayEnvelopeVersion: Int?
    public var supportsHpkeV3: Bool?
    public var relayCapable: Bool?
    public var revokedAt: String?
    public var createdAt: String
    public var updatedAt: String
    public var schemaVersion: Int
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreHermesGatewayClientDoc(
    val id: String = "",
    val uid: String = "",
    val displayName: String = "",
    val status: String = "",
    val tokenHash: String = "",
    val tokenPreview: String = "",
    val scopes: List<String> = emptyList(),
    val homeDestinationId: String = "",
    val lastSeenAt: String? = null,
    val runtimeModelId: String? = null,
    val runtimeProviderId: String? = null,
    val runtimeModelOptions: List<FirestoreHermesGatewayModelOptionDoc> = emptyList(),
    val runtimeUpdatedAt: String? = null,
    val agentVersion: String? = null,
    val pendingModelId: String? = null,
    val pendingModelRequestedAt: String? = null,
    val oversightMode: String? = null,
    val relayPublicKey: String? = null,
    val relayKeyVersion: Long? = null,
    val relayEncryption: String? = null,
    val agentRelayPublicKey: String? = null,
    val agentRelayKeyVersion: Long? = null,
    val agentRelayEncryption: String? = null,
    val agentSupportsRelayEnvelopeVersions: List<Long> = emptyList(),
    val agentPreferredRelayEnvelopeVersion: Long? = null,
    val agentSupportsHpkeV3: Boolean? = null,
    val agentPlatform: String? = null,
    val agentAppBuild: String? = null,
    val phoneRelayPublicKey: String? = null,
    val phoneRelayKeyVersion: Long? = null,
    val phoneRelayEncryption: String? = null,
    val phoneSupportsRelayEnvelopeVersions: List<Long> = emptyList(),
    val phonePreferredRelayEnvelopeVersion: Long? = null,
    val phoneSupportsHpkeV3: Boolean? = null,
    val phonePlatform: String? = null,
    val phoneAppBuild: String? = null,
    val agentRatchetIdentityPublicKey: String? = null,
    val agentRatchetSigningPublicKey: String? = null,
    val agentRatchetSignedPreKeyPublicKey: String? = null,
    val agentRatchetSignedPreKeyId: String? = null,
    val agentRatchetSignedPreKeySignature: String? = null,
    val agentSupportsRatchetV1: Boolean? = null,
    val phoneRatchetIdentityPublicKey: String? = null,
    val phoneRatchetSigningPublicKey: String? = null,
    val phoneRatchetSignedPreKeyPublicKey: String? = null,
    val phoneRatchetSignedPreKeyId: String? = null,
    val phoneRatchetSignedPreKeySignature: String? = null,
    val phoneSupportsRatchetV1: Boolean? = null,
    val supportsRatchetV1: Boolean? = null,
    val supportsRelayEnvelopeVersions: List<Long> = emptyList(),
    val preferredRelayEnvelopeVersion: Long? = null,
    val supportsHpkeV3: Boolean? = null,
    val relayCapable: Boolean? = null,
    val revokedAt: String? = null,
    val createdAt: String = "",
    val updatedAt: String = "",
    val schemaVersion: Long = 0,
)`,
      },
      HermesGatewayApprovalDoc: {
        ts: `export interface HermesGatewayApprovalDoc {
  id: string;
  clientId: string;
  destinationId: string;
  actionId: string;
  toolName?: string;
  summary: string;
  status: string;
  requestedAt: string;
  expiresAt: string;
  respondedAt?: string;
  approvedByDeviceId?: string;
  schemaVersion: number;
}`,
        swift: `public struct FirestoreHermesGatewayApprovalDoc: Codable, Sendable, Equatable {
    public var id: String
    public var clientId: String
    public var destinationId: String
    public var actionId: String
    public var toolName: String?
    public var summary: String
    public var status: String
    public var requestedAt: String
    public var expiresAt: String
    public var respondedAt: String?
    public var approvedByDeviceId: String?
    public var schemaVersion: Int
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreHermesGatewayApprovalDoc(
    val id: String = "",
    val clientId: String = "",
    val destinationId: String = "",
    val actionId: String = "",
    val toolName: String? = null,
    val summary: String = "",
    val status: String = "",
    val requestedAt: String = "",
    val expiresAt: String = "",
    val respondedAt: String? = null,
    val approvedByDeviceId: String? = null,
    val schemaVersion: Long = 0,
)`,
      },
      HermesGatewayDestinationDoc: {
        ts: `export interface HermesGatewayDestinationDoc {
  id: string;
  displayName: string;
  kind: string;
  status: string;
  isDefault: boolean;
  createdAt: string;
  updatedAt: string;
  schemaVersion: number;
}`,
        swift: `public struct FirestoreHermesGatewayDestinationDoc: Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var kind: String
    public var status: String
    public var isDefault: Bool
    public var createdAt: String
    public var updatedAt: String
    public var schemaVersion: Int
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreHermesGatewayDestinationDoc(
    val id: String = "",
    val displayName: String = "",
    val kind: String = "",
    val status: String = "",
    val isDefault: Boolean = false,
    val createdAt: String = "",
    val updatedAt: String = "",
    val schemaVersion: Long = 0,
)`,
      },
      HermesGatewayEventDoc: {
        ts: `export interface HermesGatewayEventDoc {
  id: string;
  sequence: number;
  kind: string;
  destinationId: string;
  targetClientId?: string;
  threadId?: string;
  senderId: string;
  senderDisplayName?: string;
  text?: string;
  modelId?: string;
  attachmentIds: string[];
  relayEnvelope?: GatewayRelayEnvelopeDoc;
  ratchetEnvelope?: GatewayRatchetEnvelopeDoc;
  createdAt: string;
  schemaVersion: number;
}`,
        swift: `public struct FirestoreHermesGatewayEventDoc: Codable, Sendable, Equatable {
    public var id: String
    public var sequence: Int
    public var kind: String
    public var destinationId: String
    public var targetClientId: String?
    public var threadId: String?
    public var senderId: String
    public var senderDisplayName: String?
    public var text: String?
    public var modelId: String?
    public var attachmentIds: [String]
    public var relayEnvelope: FirestoreGatewayRelayEnvelopeDoc?
    public var ratchetEnvelope: FirestoreGatewayRatchetEnvelopeDoc?
    public var createdAt: String
    public var schemaVersion: Int
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreHermesGatewayEventDoc(
    val id: String = "",
    val sequence: Long = 0,
    val kind: String = "",
    val destinationId: String = "",
    val targetClientId: String? = null,
    val threadId: String? = null,
    val senderId: String = "",
    val senderDisplayName: String? = null,
    val text: String? = null,
    val modelId: String? = null,
    val attachmentIds: List<String> = emptyList(),
    val relayEnvelope: FirestoreGatewayRelayEnvelopeDoc? = null,
    val ratchetEnvelope: FirestoreGatewayRatchetEnvelopeDoc? = null,
    val createdAt: String = "",
    val schemaVersion: Long = 0,
)`,
      },
      HermesGatewayMessageDoc: {
        ts: `export interface HermesGatewayMessageDoc {
  id: string;
  clientId: string;
  kind: string;
  destinationId: string;
  threadId?: string;
  replyToEventId?: string;
  text?: string;
  attachmentIds: string[];
  relayEnvelope?: GatewayRelayEnvelopeDoc;
  ratchetEnvelope?: GatewayRatchetEnvelopeDoc;
  createdAt: string;
  schemaVersion: number;
}`,
        swift: `public struct FirestoreHermesGatewayMessageDoc: Codable, Sendable, Equatable {
    public var id: String
    public var clientId: String
    public var kind: String
    public var destinationId: String
    public var threadId: String?
    public var replyToEventId: String?
    public var text: String?
    public var attachmentIds: [String]
    public var relayEnvelope: FirestoreGatewayRelayEnvelopeDoc?
    public var ratchetEnvelope: FirestoreGatewayRatchetEnvelopeDoc?
    public var createdAt: String
    public var schemaVersion: Int
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreHermesGatewayMessageDoc(
    val id: String = "",
    val clientId: String = "",
    val kind: String = "",
    val destinationId: String = "",
    val threadId: String? = null,
    val replyToEventId: String? = null,
    val text: String? = null,
    val attachmentIds: List<String> = emptyList(),
    val relayEnvelope: FirestoreGatewayRelayEnvelopeDoc? = null,
    val ratchetEnvelope: FirestoreGatewayRatchetEnvelopeDoc? = null,
    val createdAt: String = "",
    val schemaVersion: Long = 0,
)`,
      },
      HermesGatewayAttachmentManifestDoc: {
        ts: `export interface HermesGatewayAttachmentManifestDoc {
  id: string;
  clientId: string;
  destinationId?: string;
  fileName?: string;
  contentType?: string;
  byteCount?: number;
  storagePath?: string;
  bodyStoragePath?: string;
  status?: string;
  relayEnvelope?: GatewayRelayEnvelopeDoc;
  ratchetEnvelope?: GatewayRatchetEnvelopeDoc;
  createdAt: string;
  expiresAt: string;
  schemaVersion: number;
}`,
        swift: `public struct FirestoreHermesGatewayAttachmentManifestDoc: Codable, Sendable, Equatable {
    public var id: String
    public var clientId: String
    public var destinationId: String?
    public var fileName: String?
    public var contentType: String?
    public var byteCount: Int?
    public var storagePath: String?
    public var bodyStoragePath: String?
    public var status: String?
    public var relayEnvelope: FirestoreGatewayRelayEnvelopeDoc?
    public var ratchetEnvelope: FirestoreGatewayRatchetEnvelopeDoc?
    public var createdAt: String
    public var expiresAt: String
    public var schemaVersion: Int
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreHermesGatewayAttachmentManifestDoc(
    val id: String = "",
    val clientId: String = "",
    val destinationId: String? = null,
    val fileName: String? = null,
    val contentType: String? = null,
    val byteCount: Long? = null,
    val storagePath: String? = null,
    val bodyStoragePath: String? = null,
    val status: String? = null,
    val relayEnvelope: FirestoreGatewayRelayEnvelopeDoc? = null,
    val ratchetEnvelope: FirestoreGatewayRatchetEnvelopeDoc? = null,
    val createdAt: String = "",
    val expiresAt: String = "",
    val schemaVersion: Long = 0,
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
      CapabilityToken: {
        ts: `export interface CapabilityToken {
  schemaVersion: number;
  domain: "remote_unlock" | "computer_use";
  nonce: string;
  issuedAt: string;
  expiresAt: string;
  allowedActionKinds: string[];
  scopeHash: string;
  actionBudget: number;
  boundEscrowDeviceId?: string;
  attestationHashBlake3?: string;
  signatureEd25519Base64?: string;
}`,
        swift: null,
        kotlin: null,
      },
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
  "device-links": {
    models: {
      ProviderAccountDeviceLinkDoc: {
        ts: `export interface ProviderAccountDeviceLinkDoc {
  id: string;
  accountID: string;
  deviceID: string;
  deviceDisplayName: string;
  capability: string;
  status: string;
  lastObservedAt: string;
  createdAt: string;
  updatedAt: string;
  schemaVersion: number;
}`,
        swift: `/// Firestore: users/{uid}/provider_account_device_links/{accountID}_{deviceID}
public struct FirestoreProviderAccountDeviceLinkDoc: Codable, Sendable, Equatable {
    public var id: String
    public var accountID: String
    public var deviceID: String
    public var deviceDisplayName: String
    public var capability: String
    public var status: String
    public var lastObservedAt: String
    public var createdAt: String
    public var updatedAt: String
    public var schemaVersion: Int
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreProviderAccountDeviceLinkDoc(
    val id: String = "",
    @get:PropertyName("accountID") @set:PropertyName("accountID")
    var accountId: String = "",
    @get:PropertyName("deviceID") @set:PropertyName("deviceID")
    var deviceId: String = "",
    val deviceDisplayName: String = "",
    val capability: String = "",
    val status: String = "",
    val lastObservedAt: String = "",
    val createdAt: String = "",
    val updatedAt: String = "",
    val schemaVersion: Long = 0,
)`,
      },
    },
  },
  "model-benchmarks": {
    models: {
      ModelBenchmarkSnapshotDoc: {
        ts: `export interface ModelBenchmarkSnapshotDoc {
  id: string;
  source: string;
  sourceURL?: string;
  attribution?: string;
  fetchedAt: string;
  modelID: string;
  providerID?: string;
  taskCategory: string;
  score?: number;
  rank?: number;
  costSignal?: number;
  inputCostPerMtoken?: number;
  outputCostPerMtoken?: number;
  blendedCostPerMtoken?: number;
  latencySignal?: number;
  contextWindowTokens?: number;
  reliabilitySignal?: number;
  confidence?: number;
  freshness: string;
  schemaVersion: number;
  updatedAt: string;
}`,
        swift: `/// Firestore: model_benchmark_snapshots/{source_model_task_timestamp}
public struct FirestoreModelBenchmarkSnapshotDoc: Codable, Sendable, Equatable {
    public var id: String
    public var source: String
    public var sourceURL: String?
    public var attribution: String?
    public var fetchedAt: String
    public var modelID: String
    public var providerID: String?
    public var taskCategory: String
    public var score: Double?
    public var rank: Int?
    public var costSignal: Double?
    public var inputCostPerMtoken: Double?
    public var outputCostPerMtoken: Double?
    public var blendedCostPerMtoken: Double?
    public var latencySignal: Double?
    public var contextWindowTokens: Int?
    public var reliabilitySignal: Double?
    public var confidence: Double?
    public var freshness: String
    public var schemaVersion: Int
    public var updatedAt: String
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreModelBenchmarkSnapshotDoc(
    val id: String = "",
    val source: String = "",
    val sourceURL: String? = null,
    val attribution: String? = null,
    val fetchedAt: String = "",
    @get:PropertyName("modelID") @set:PropertyName("modelID")
    var modelId: String = "",
    @get:PropertyName("providerID") @set:PropertyName("providerID")
    var providerId: String? = null,
    val taskCategory: String = "",
    val score: Double? = null,
    val rank: Long? = null,
    val costSignal: Double? = null,
    val inputCostPerMtoken: Double? = null,
    val outputCostPerMtoken: Double? = null,
    val blendedCostPerMtoken: Double? = null,
    val latencySignal: Double? = null,
    val contextWindowTokens: Long? = null,
    val reliabilitySignal: Double? = null,
    val confidence: Double? = null,
    val freshness: String = "",
    val schemaVersion: Long = 0,
    val updatedAt: String = "",
)`,
      },
      ModelBenchmarkSourceStatusDoc: {
        ts: `export interface ModelBenchmarkSourceStatusDoc {
  source: string;
  status: string;
  fetchedAt?: string;
  message: string;
  attribution?: string;
  schemaVersion: number;
  updatedAt: string;
}`,
        swift: `/// Firestore: model_benchmark_source_status/{source}
public struct FirestoreModelBenchmarkSourceStatusDoc: Codable, Sendable, Equatable {
    public var source: String
    public var status: String
    public var fetchedAt: String?
    public var message: String
    public var attribution: String?
    public var schemaVersion: Int
    public var updatedAt: String
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreModelBenchmarkSourceStatusDoc(
    val source: String = "",
    val status: String = "",
    val fetchedAt: String? = null,
    val message: String = "",
    val attribution: String? = null,
    val schemaVersion: Long = 0,
    val updatedAt: String = "",
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
