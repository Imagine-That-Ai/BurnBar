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
  executionSourceID?: string;
  executionSourceName?: string;
  executionSourceKind?: string;
  executionSourceConfidence?: string;
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
    public var executionSourceID: String?
    public var executionSourceName: String?
    public var executionSourceKind: String?
    public var executionSourceConfidence: String?
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
    @get:PropertyName("executionSourceID") @set:PropertyName("executionSourceID")
    var executionSourceId: String? = null,
    val executionSourceName: String? = null,
    val executionSourceKind: String? = null,
    val executionSourceConfidence: String? = null,
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
  status: "connected" | "deleted" | "disabled" | "disconnected" | "error" | "stale";
  credentialKind: "bearer" | "cookie" | "plan" | "session" | "token";
  storageScope: "cloud_refreshable" | "device_keychain" | "local_only" | "server_private";
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
      GatewaySignalCiphertextLayerDoc: {
        ts: `export interface GatewaySignalCiphertextLayerDoc {
  payloadCiphertextB64: string;
  payloadAADLabel: string;
  schemaVersion: number;
}`,
        swift: `public struct FirestoreGatewaySignalCiphertextLayerDoc: Codable, Sendable, Equatable {
    public var payloadCiphertextB64: String
    public var payloadAADLabel: String
    public var schemaVersion: Int
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreGatewaySignalCiphertextLayerDoc(
    val payloadCiphertextB64: String = "",
    val payloadAADLabel: String = "",
    val schemaVersion: Long = 0,
)`,
      },
      GatewaySignalBindingDoc: {
        ts: `export interface GatewaySignalBindingDoc {
  uid: string;
  scope: "gateway" | "cloudvault";
  clientId?: string;
  collection?: string;
  docId?: string;
  field?: string;
  slotId?: string;
  mode: "transport" | "at-rest";
  formatVersion: number;
}`,
        swift: `public struct FirestoreGatewaySignalBindingDoc: Codable, Sendable, Equatable {
    public var uid: String
    public var scope: String
    public var clientId: String?
    public var collection: String?
    public var docId: String?
    public var field: String?
    public var slotId: String?
    public var mode: String
    public var formatVersion: Int
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreGatewaySignalBindingDoc(
    val uid: String = "",
    val scope: String = "",
    val clientId: String? = null,
    val collection: String? = null,
    val docId: String? = null,
    val field: String? = null,
    val slotId: String? = null,
    val mode: String = "",
    val formatVersion: Long = 0,
)`,
      },
      GatewaySignalAtRestWrapDoc: {
        ts: `export interface GatewaySignalAtRestWrapDoc {
  recipientKind: "device" | "escrow" | "recovery";
  recipientIdentityKeyId: string;
  recipientIdentityKeyB64: string;
  sealedContentKeyB64: string;
}`,
        swift: `public struct FirestoreGatewaySignalAtRestWrapDoc: Codable, Sendable, Equatable {
    public var recipientKind: String
    public var recipientIdentityKeyId: String
    public var recipientIdentityKeyB64: String
    public var sealedContentKeyB64: String
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreGatewaySignalAtRestWrapDoc(
    val recipientKind: String = "",
    val recipientIdentityKeyId: String = "",
    val recipientIdentityKeyB64: String = "",
    val sealedContentKeyB64: String = "",
)`,
      },
      GatewaySignalKeyDeliveryDoc: {
        ts: `export interface GatewaySignalTransportKeyDeliveryDoc {
  scheme: "signal-doubleratchet-pqxdh-v1";
  signalMessageType: 2 | 3;
  signalMessageB64: string;
  senderIdentityKeyId: string;
  ratchetEpochHint?: number;
}

export interface GatewaySignalAtRestKeyDeliveryDoc {
  scheme: "signal-hpke-identity-seal-v1";
  wraps: GatewaySignalAtRestWrapDoc[];
  contentKeyLength: 32;
}`,
        swift: `public struct FirestoreGatewaySignalKeyDeliveryDoc: Codable, Sendable, Equatable {
    public var scheme: String
    public var signalMessageType: Int?
    public var signalMessageB64: String?
    public var senderIdentityKeyId: String?
    public var ratchetEpochHint: Int?
    public var wraps: [FirestoreGatewaySignalAtRestWrapDoc]?
    public var contentKeyLength: Int?
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreGatewaySignalKeyDeliveryDoc(
    val scheme: String = "",
    val signalMessageType: Long? = null,
    val signalMessageB64: String? = null,
    val senderIdentityKeyId: String? = null,
    val ratchetEpochHint: Long? = null,
    val wraps: List<FirestoreGatewaySignalAtRestWrapDoc>? = null,
    val contentKeyLength: Long? = null,
)`,
      },
      GatewaySignalAtRestSenderAuthDoc: {
        ts: `export interface GatewaySignalAtRestSenderAuthDoc {
  senderIdentityKeyId: string;
  senderIdentityKeyB64: string;
  signatureB64: string;
  signatureVersion: 1;
}`,
        swift: `public struct FirestoreGatewaySignalAtRestSenderAuthDoc: Codable, Sendable, Equatable {
    public var senderIdentityKeyId: String
    public var senderIdentityKeyB64: String
    public var signatureB64: String
    public var signatureVersion: Int
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreGatewaySignalAtRestSenderAuthDoc(
    val senderIdentityKeyId: String = "",
    val senderIdentityKeyB64: String = "",
    val signatureB64: String = "",
    val signatureVersion: Long = 1,
)`,
      },
      GatewaySignalEnvelopeDoc: {
        ts: `export interface GatewaySignalEnvelopeDoc {
  signalEnvelopeFormatVersion: number;
  mode: "transport" | "at-rest";
  relayKeyVersion?: number;
  relayEncryption: "signal-doubleratchet-pqxdh-v1" | "signal-hpke-identity-seal-v1";
  ciphertextLayer: GatewaySignalCiphertextLayerDoc;
  keyDelivery: GatewaySignalTransportKeyDeliveryDoc | GatewaySignalAtRestKeyDeliveryDoc;
  binding: GatewaySignalBindingDoc;
  senderAuth?: GatewaySignalAtRestSenderAuthDoc;
}`,
        swift: `public struct FirestoreGatewaySignalEnvelopeDoc: Codable, Sendable, Equatable {
    public var signalEnvelopeFormatVersion: Int
    public var mode: String
    public var relayKeyVersion: Int?
    public var relayEncryption: String
    public var ciphertextLayer: FirestoreGatewaySignalCiphertextLayerDoc
    public var keyDelivery: FirestoreGatewaySignalKeyDeliveryDoc
    public var binding: FirestoreGatewaySignalBindingDoc
    public var senderAuth: FirestoreGatewaySignalAtRestSenderAuthDoc?
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreGatewaySignalEnvelopeDoc(
    val signalEnvelopeFormatVersion: Long = 0,
    val mode: String = "",
    val relayKeyVersion: Long? = null,
    val relayEncryption: String = "",
    val ciphertextLayer: FirestoreGatewaySignalCiphertextLayerDoc = FirestoreGatewaySignalCiphertextLayerDoc(),
    val keyDelivery: FirestoreGatewaySignalKeyDeliveryDoc = FirestoreGatewaySignalKeyDeliveryDoc(),
    val binding: FirestoreGatewaySignalBindingDoc = FirestoreGatewaySignalBindingDoc(),
    val senderAuth: FirestoreGatewaySignalAtRestSenderAuthDoc? = null,
)`,
      },
      HermesGatewaySignalPrekeyBundleDoc: {
        ts: `export interface HermesGatewaySignalPrekeyBundleDoc {
  version: 1;
  bundleId: string;
  identityKeyId: string;
  identityKeyB64: string;
  registrationId: number;
  deviceId: number;
  signedPreKeyId: number;
  signedPreKeyPublicB64: string;
  signedPreKeySignatureB64: string;
  oneTimePreKeyId: number;
  oneTimePreKeyPublicB64: string;
  kyberPreKeyId: number;
  kyberPreKeyPublicB64: string;
  kyberPreKeySignatureB64: string;
  generatedAt: string;
}`,
        swift: `public struct FirestoreHermesGatewaySignalPrekeyBundleDoc: Codable, Sendable, Equatable {
    public var version: Int
    public var bundleId: String
    public var identityKeyId: String
    public var identityKeyB64: String
    public var registrationId: Int
    public var deviceId: Int
    public var signedPreKeyId: Int
    public var signedPreKeyPublicB64: String
    public var signedPreKeySignatureB64: String
    public var oneTimePreKeyId: Int
    public var oneTimePreKeyPublicB64: String
    public var kyberPreKeyId: Int
    public var kyberPreKeyPublicB64: String
    public var kyberPreKeySignatureB64: String
    public var generatedAt: String
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreHermesGatewaySignalPrekeyBundleDoc(
    val version: Long = 1,
    val bundleId: String = "",
    val identityKeyId: String = "",
    val identityKeyB64: String = "",
    val registrationId: Long = 0,
    val deviceId: Long = 0,
    val signedPreKeyId: Long = 0,
    val signedPreKeyPublicB64: String = "",
    val signedPreKeySignatureB64: String = "",
    val oneTimePreKeyId: Long = 0,
    val oneTimePreKeyPublicB64: String = "",
    val kyberPreKeyId: Long = 0,
    val kyberPreKeyPublicB64: String = "",
    val kyberPreKeySignatureB64: String = "",
    val generatedAt: String = "",
)`,
      },
      HermesGatewayClientDoc: {
        ts: `export interface HermesGatewayClientDoc {
  id: string;
  uid: string;
  displayName: string;
  status: "active" | "revoked";
  tokenHash: string;
  tokenPreview: string;
  agentClientSigningPublicKeyBase64?: string;
  agentClientSigningKeyId?: string;
  popRequired?: boolean;
  popVersion?: number;
  scopes: ("hermes.gateway.read" | "hermes.gateway.write" | "hermes.gateway.manage")[];
  homeDestinationId: string;
  expiresAt?: string;
  rotatedAt?: string;
  lastSeenAt?: string;
  agentRelayPublicKey?: string;
  agentRelayKeyVersion?: number;
  agentRelayEncryption?: string;
  agentSupportsRelayEnvelopeVersions?: number[];
  agentPreferredRelayEnvelopeVersion?: number;
  agentSupportsHpkeV3?: boolean;
  agentSupportsSignalEnvelope?: boolean;
  agentSignalPrekeyBundle?: HermesGatewaySignalPrekeyBundleDoc;
  agentPlatform?: string;
  agentAppBuild?: string;
  phoneRelayPublicKey?: string;
  phoneRelayKeyVersion?: number;
  phoneRelayEncryption?: string;
  phoneSupportsRelayEnvelopeVersions?: number[];
  phonePreferredRelayEnvelopeVersion?: number;
  phoneSupportsHpkeV3?: boolean;
  phoneSupportsSignalEnvelope?: boolean;
  phoneSignalPrekeyBundle?: HermesGatewaySignalPrekeyBundleDoc;
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
  supportsSignalEnvelope?: boolean;
  relayCapable?: boolean;
  runtimeModelId?: string;
  runtimeProviderId?: string;
  runtimeModelOptions?: HermesGatewayModelOptionDoc[];
  runtimeUpdatedAt?: string;
  agentVersion?: string;
  pendingModelId?: string;
  pendingModelRequestedAt?: string;
  oversightMode?: "supervised" | "autonomous";
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
    public var agentClientSigningPublicKeyBase64: String?
    public var agentClientSigningKeyId: String?
    public var popRequired: Bool?
    public var popVersion: Int?
    public var scopes: [String]
    public var homeDestinationId: String
    public var expiresAt: String?
    public var rotatedAt: String?
    public var lastSeenAt: String?
    public var agentRelayPublicKey: String?
    public var agentRelayKeyVersion: Int?
    public var agentRelayEncryption: String?
    public var agentSupportsRelayEnvelopeVersions: [Int]?
    public var agentPreferredRelayEnvelopeVersion: Int?
    public var agentSupportsHpkeV3: Bool?
    public var agentSupportsSignalEnvelope: Bool?
    public var agentSignalPrekeyBundle: FirestoreHermesGatewaySignalPrekeyBundleDoc?
    public var agentPlatform: String?
    public var agentAppBuild: String?
    public var phoneRelayPublicKey: String?
    public var phoneRelayKeyVersion: Int?
    public var phoneRelayEncryption: String?
    public var phoneSupportsRelayEnvelopeVersions: [Int]?
    public var phonePreferredRelayEnvelopeVersion: Int?
    public var phoneSupportsHpkeV3: Bool?
    public var phoneSupportsSignalEnvelope: Bool?
    public var phoneSignalPrekeyBundle: FirestoreHermesGatewaySignalPrekeyBundleDoc?
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
    public var supportsSignalEnvelope: Bool?
    public var relayCapable: Bool?
    public var runtimeModelId: String?
    public var runtimeProviderId: String?
    public var runtimeModelOptions: [FirestoreHermesGatewayModelOptionDoc]?
    public var runtimeUpdatedAt: String?
    public var agentVersion: String?
    public var pendingModelId: String?
    public var pendingModelRequestedAt: String?
    public var oversightMode: String?
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
    val agentClientSigningPublicKeyBase64: String? = null,
    val agentClientSigningKeyId: String? = null,
    val popRequired: Boolean? = null,
    val popVersion: Long? = null,
    val scopes: List<String> = emptyList(),
    val homeDestinationId: String = "",
    val expiresAt: String? = null,
    val rotatedAt: String? = null,
    val lastSeenAt: String? = null,
    val agentRelayPublicKey: String? = null,
    val agentRelayKeyVersion: Long? = null,
    val agentRelayEncryption: String? = null,
    val agentSupportsRelayEnvelopeVersions: List<Long> = emptyList(),
    val agentPreferredRelayEnvelopeVersion: Long? = null,
    val agentSupportsHpkeV3: Boolean? = null,
    val agentSupportsSignalEnvelope: Boolean? = null,
    val agentSignalPrekeyBundle: FirestoreHermesGatewaySignalPrekeyBundleDoc? = null,
    val agentPlatform: String? = null,
    val agentAppBuild: String? = null,
    val phoneRelayPublicKey: String? = null,
    val phoneRelayKeyVersion: Long? = null,
    val phoneRelayEncryption: String? = null,
    val phoneSupportsRelayEnvelopeVersions: List<Long> = emptyList(),
    val phonePreferredRelayEnvelopeVersion: Long? = null,
    val phoneSupportsHpkeV3: Boolean? = null,
    val phoneSupportsSignalEnvelope: Boolean? = null,
    val phoneSignalPrekeyBundle: FirestoreHermesGatewaySignalPrekeyBundleDoc? = null,
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
    val supportsSignalEnvelope: Boolean? = null,
    val relayCapable: Boolean? = null,
    val runtimeModelId: String? = null,
    val runtimeProviderId: String? = null,
    val runtimeModelOptions: List<FirestoreHermesGatewayModelOptionDoc> = emptyList(),
    val runtimeUpdatedAt: String? = null,
    val agentVersion: String? = null,
    val pendingModelId: String? = null,
    val pendingModelRequestedAt: String? = null,
    val oversightMode: String? = null,
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
  status: "waiting_for_approval" | "approved" | "rejected" | "expired";
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
  kind: "home" | "chat" | "thread";
  status: "active" | "archived";
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
  kind: "message" | "model_switch";
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
  signalEnvelope?: GatewaySignalEnvelopeDoc;
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
    public var signalEnvelope: FirestoreGatewaySignalEnvelopeDoc?
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
    val signalEnvelope: FirestoreGatewaySignalEnvelopeDoc? = null,
    val createdAt: String = "",
    val schemaVersion: Long = 0,
)`,
      },
      HermesGatewayMessageDoc: {
        ts: `export interface HermesGatewayMessageDoc {
  id: string;
  clientId: string;
  kind: "agent_message" | "typing";
  destinationId: string;
  threadId?: string;
  replyToEventId?: string;
  text?: string;
  relayEnvelope?: GatewayRelayEnvelopeDoc;
  ratchetEnvelope?: GatewayRatchetEnvelopeDoc;
  signalEnvelope?: GatewaySignalEnvelopeDoc;
  attachmentIds: string[];
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
    public var signalEnvelope: FirestoreGatewaySignalEnvelopeDoc?
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
    val signalEnvelope: FirestoreGatewaySignalEnvelopeDoc? = null,
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
  contentType: string;
  byteCount: number;
  storagePath: string;
  status: "pending_upload" | "uploaded" | "failed" | "expired" | "rejected";
  relayEnvelope?: GatewayRelayEnvelopeDoc;
  ratchetEnvelope?: GatewayRatchetEnvelopeDoc;
  signalEnvelope?: GatewaySignalEnvelopeDoc;
  createdAt: string;
  updatedAt?: string;
  expiresAt: string;
  uploadedAt?: string;
  finalizedAt?: string;
  sha256?: string;
  storageGeneration?: string;
  schemaVersion: number;
}`,
        swift: `public struct FirestoreHermesGatewayAttachmentManifestDoc: Codable, Sendable, Equatable {
    public var id: String
    public var clientId: String
    public var destinationId: String?
    public var fileName: String?
    public var contentType: String
    public var byteCount: Int
    public var storagePath: String
    public var status: String
    public var relayEnvelope: FirestoreGatewayRelayEnvelopeDoc?
    public var ratchetEnvelope: FirestoreGatewayRatchetEnvelopeDoc?
    public var signalEnvelope: FirestoreGatewaySignalEnvelopeDoc?
    public var createdAt: String
    public var updatedAt: String?
    public var expiresAt: String
    public var uploadedAt: String?
    public var finalizedAt: String?
    public var sha256: String?
    public var storageGeneration: String?
    public var schemaVersion: Int
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreHermesGatewayAttachmentManifestDoc(
    val id: String = "",
    val clientId: String = "",
    val destinationId: String? = null,
    val fileName: String? = null,
    val contentType: String = "",
    val byteCount: Long = 0,
    val storagePath: String = "",
    val status: String = "",
    val relayEnvelope: FirestoreGatewayRelayEnvelopeDoc? = null,
    val ratchetEnvelope: FirestoreGatewayRatchetEnvelopeDoc? = null,
    val signalEnvelope: FirestoreGatewaySignalEnvelopeDoc? = null,
    val createdAt: String = "",
    val updatedAt: String? = null,
    val expiresAt: String = "",
    val uploadedAt: String? = null,
    val finalizedAt: String? = null,
    val sha256: String? = null,
    val storageGeneration: String? = null,
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
      IrohControllerRouteDoc: {
        ts: `export interface IrohControllerRouteDoc {
  connectionId: string;
  sourceDeviceId: string;
  transportNodeId: string;
  authorityPeerNodeId: string;
  authorityPublicKeySHA256: string;
  status: string;
  generation: number;
  registeredAtMillis: number;
  expiresAtMillis: number;
  revokedAtMillis?: number;
  schemaVersion: number;
  updatedAt: string;
}`,
        swift: `public struct FirestoreIrohControllerRouteDoc: Codable, Sendable, Equatable {
    public var connectionId: String
    public var sourceDeviceId: String
    public var transportNodeId: String
    public var authorityPeerNodeId: String
    public var authorityPublicKeySHA256: String
    public var status: String
    public var generation: Int64
    public var registeredAtMillis: Int64
    public var expiresAtMillis: Int64
    public var revokedAtMillis: Int64?
    public var schemaVersion: Int64
    public var updatedAt: String
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreIrohControllerRouteDoc(
    val connectionId: String = "",
    val sourceDeviceId: String = "",
    val transportNodeId: String = "",
    val authorityPeerNodeId: String = "",
    val authorityPublicKeySHA256: String = "",
    val status: String = "",
    val generation: Long = 0,
    val registeredAtMillis: Long = 0,
    val expiresAtMillis: Long = 0,
    val revokedAtMillis: Long? = null,
    val schemaVersion: Long = 0,
    val updatedAt: String = "",
)`,
      },
      IrohControllerRouteChallengeDoc: {
        ts: `export interface IrohControllerRouteChallengeDoc {
  challengeId: string;
  challengeNonce: string;
  connectionId: string;
  sourceDeviceId: string;
  transportNodeId: string;
  authorityPeerNodeId: string;
  proofKind: string;
  expectedPriorGeneration: number;
  expectedRegisteredAtMillis?: number;
  registrationGeneration: number;
  canonicalPayloadBase64: string;
  issuedAtMillis: number;
  expiresAtMillis: number;
  status: string;
  consumedAtMillis?: number;
  schemaVersion: number;
  expireAt: string;
}`,
        swift: `public struct FirestoreIrohControllerRouteChallengeDoc: Codable, Sendable, Equatable {
    public var challengeId: String
    public var challengeNonce: String
    public var connectionId: String
    public var sourceDeviceId: String
    public var transportNodeId: String
    public var authorityPeerNodeId: String
    public var proofKind: String
    public var expectedPriorGeneration: Int64
    public var expectedRegisteredAtMillis: Int64?
    public var registrationGeneration: Int64
    public var canonicalPayloadBase64: String
    public var issuedAtMillis: Int64
    public var expiresAtMillis: Int64
    public var status: String
    public var consumedAtMillis: Int64?
    public var schemaVersion: Int64
    public var expireAt: String
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreIrohControllerRouteChallengeDoc(
    val challengeId: String = "",
    val challengeNonce: String = "",
    val connectionId: String = "",
    val sourceDeviceId: String = "",
    val transportNodeId: String = "",
    val authorityPeerNodeId: String = "",
    val proofKind: String = "",
    val expectedPriorGeneration: Long = 0,
    val expectedRegisteredAtMillis: Long? = null,
    val registrationGeneration: Long = 0,
    val canonicalPayloadBase64: String = "",
    val issuedAtMillis: Long = 0,
    val expiresAtMillis: Long = 0,
    val status: String = "",
    val consumedAtMillis: Long? = null,
    val schemaVersion: Long = 0,
    val expireAt: String = "",
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
  connectionId: string;
  peerNodeId: string;
  publicKeyBase64: string;
  publishedAtMillis: number;
  protocolVersion: number;
  schemaVersion: number;
  createdAt: string;
  updatedAt: string;
}`,
        swift: `public struct FirestoreComputerUsePhoneAuthorityDoc: Codable, Sendable, Equatable {
    public var deviceId: String
    public var connectionId: String
    public var peerNodeId: String
    public var publicKeyBase64: String
    public var publishedAtMillis: Int
    public var protocolVersion: Int
    public var schemaVersion: Int
    public var createdAt: String
    public var updatedAt: String
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreComputerUsePhoneAuthorityDoc(
    val deviceId: String = "",
    val connectionId: String = "",
    val peerNodeId: String = "",
    val publicKeyBase64: String = "",
    val publishedAtMillis: Long = 0,
    val protocolVersion: Long = 0,
    val schemaVersion: Long = 0,
    val createdAt: String = "",
    val updatedAt: String = "",
)`,
      },
      RelaySenderKeyDoc: {
        ts: `export interface RelaySenderKeyDoc {
  id: string;
  deviceId: string;
  peerNodeId: string;
  keyId: string;
  publicKeyBase64: string;
  relayKeyVersion: number;
  relayEncryption: string;
  signalIdentityKeyVersion: number;
  signalIdentityFingerprint: string;
  signalIdentityVerification: "verified";
  status: "active" | "revoked";
  publishedAtMillis: number;
  createdAt: string;
  updatedAt: string;
  schemaVersion: number;
}`,
        swift: `public struct FirestoreRelaySenderKeyDoc: Codable, Sendable, Equatable {
    public var id: String
    public var deviceId: String
    public var peerNodeId: String
    public var keyId: String
    public var publicKeyBase64: String
    public var relayKeyVersion: Int
    public var relayEncryption: String
    public var signalIdentityKeyVersion: Int
    public var signalIdentityFingerprint: String
    public var signalIdentityVerification: String
    public var status: String
    public var publishedAtMillis: Int
    public var createdAt: String
    public var updatedAt: String
    public var schemaVersion: Int
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreRelaySenderKeyDoc(
    val id: String = "",
    val deviceId: String = "",
    val peerNodeId: String = "",
    val keyId: String = "",
    val publicKeyBase64: String = "",
    val relayKeyVersion: Long = 0,
    val relayEncryption: String = "",
    val signalIdentityKeyVersion: Long = 0,
    val signalIdentityFingerprint: String = "",
    val signalIdentityVerification: String = "verified",
    val status: String = "",
    val publishedAtMillis: Long = 0,
    val createdAt: String = "",
    val updatedAt: String = "",
    val schemaVersion: Long = 0,
)`,
      },
      AgentGrantAuthorityDoc: {
        ts: `export interface AgentGrantAuthorityDoc {
  id: string;
  deviceId: string;
  peerNodeId: string;
  publicKeyBase64: string;
  authorityKind: "agent_capability_grant";
  status: "active" | "revoked";
  publishedAtMillis: number;
  createdAt: string;
  updatedAt: string;
  schemaVersion: number;
}`,
        swift: `public struct FirestoreAgentGrantAuthorityDoc: Codable, Sendable, Equatable {
    public var id: String
    public var deviceId: String
    public var peerNodeId: String
    public var publicKeyBase64: String
    public var authorityKind: String
    public var status: String
    public var publishedAtMillis: Int
    public var createdAt: String
    public var updatedAt: String
    public var schemaVersion: Int
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreAgentGrantAuthorityDoc(
    val id: String = "",
    val deviceId: String = "",
    val peerNodeId: String = "",
    val publicKeyBase64: String = "",
    val authorityKind: String = "agent_capability_grant",
    val status: String = "",
    val publishedAtMillis: Long = 0,
    val createdAt: String = "",
    val updatedAt: String = "",
    val schemaVersion: Long = 0,
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
  entitlements: {
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
  insights: {
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
  missions: {
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
  "war-room": {
    models: {
      HermesBodyHardwareDoc: {
        ts: `export interface HermesBodyHardwareDoc {
  hardwareModel?: string;
  chip?: string;
  memoryBytes?: number;
  performanceCoreCount?: number;
  efficiencyCoreCount?: number;
  osVersion?: string;
}`,
        swift: `/// Hardware a body reports about itself. Absent means "not readable here", never zero.
public struct FirestoreHermesBodyHardwareDoc: Codable, Sendable, Equatable {
    public var hardwareModel: String?
    public var chip: String?
    public var memoryBytes: Int64?
    public var performanceCoreCount: Int?
    public var efficiencyCoreCount: Int?
    public var osVersion: String?
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreHermesBodyHardwareDoc(
    val hardwareModel: String? = null,
    val chip: String? = null,
    val memoryBytes: Long? = null,
    val performanceCoreCount: Long? = null,
    val efficiencyCoreCount: Long? = null,
    val osVersion: String? = null,
)`,
      },
      HermesBodyPresenceDoc: {
        ts: `export interface HermesBodyPresenceDoc {
  state: "online" | "idle" | "offline" | "unknown";
  lastHeartbeatAt: string;
  heartbeatIntervalSeconds: number;
}`,
        swift: `/// Liveness of a body, derived from its own heartbeat.
public struct FirestoreHermesBodyPresenceDoc: Codable, Sendable, Equatable {
    public var state: String
    public var lastHeartbeatAt: String
    public var heartbeatIntervalSeconds: Int
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreHermesBodyPresenceDoc(
    val state: String = "",
    val lastHeartbeatAt: String = "",
    val heartbeatIntervalSeconds: Long = 0,
)`,
      },
      HermesBodyDoc: {
        ts: `export interface HermesBodyDoc {
  bodyId: string;
  installationId: string;
  displayName: string;
  platform: "android" | "ios" | "linux" | "macos" | "windows";
  hardware: HermesBodyHardwareDoc;
  capabilities: ("advise" | "missionRun" | "observe" | "relayClient" | "relayHost")[];
  presence: HermesBodyPresenceDoc;
  joinedAt: string;
  updatedAt: string;
  schemaVersion: number;
}`,
        swift: `/// Firestore: users/{uid}/hermes_bodies/{bodyId}
/// `+"`bodyId`"+` is the existing Hermes relay connection id — joining mints no new identity.
public struct FirestoreHermesBodyDoc: Codable, Sendable, Equatable {
    public var bodyId: String
    public var installationId: String
    public var displayName: String
    public var platform: String
    public var hardware: FirestoreHermesBodyHardwareDoc
    public var capabilities: [String]
    public var presence: FirestoreHermesBodyPresenceDoc
    public var joinedAt: String
    public var updatedAt: String
    public var schemaVersion: Int
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreHermesBodyDoc(
    val bodyId: String = "",
    val installationId: String = "",
    val displayName: String = "",
    val platform: String = "",
    val hardware: FirestoreHermesBodyHardwareDoc = FirestoreHermesBodyHardwareDoc(),
    val capabilities: List<String> = emptyList(),
    val presence: FirestoreHermesBodyPresenceDoc = FirestoreHermesBodyPresenceDoc(),
    val joinedAt: String = "",
    val updatedAt: String = "",
    val schemaVersion: Long = 0,
)`,
      },
      OriginatorDoc: {
        ts: `export interface OriginatorDoc {
  bodyId: string;
  kind: "agent" | "daemon" | "human" | "mission" | "unknown";
  surface: string;
  confidence: "exact" | "inferred" | "unknown";
  provenanceDetail?: string;
  label?: string;
  missionId?: string;
  runId?: string;
  recordedAt: string;
  schemaVersion: number;
}`,
        swift: `/// Who caused a write. Embedded in usage, mission, and run documents.
/// Only a write the daemon itself spawned may claim `+"`exact`"+` confidence.
public struct FirestoreOriginatorDoc: Codable, Sendable, Equatable {
    public var bodyId: String
    public var kind: String
    public var surface: String
    public var confidence: String
    public var provenanceDetail: String?
    public var label: String?
    public var missionId: String?
    public var runId: String?
    public var recordedAt: String
    public var schemaVersion: Int
}`,
        kotlin: `@Keep
@IgnoreExtraProperties
data class FirestoreOriginatorDoc(
    val bodyId: String = "",
    val kind: String = "",
    val surface: String = "",
    val confidence: String = "",
    val provenanceDetail: String? = null,
    val label: String? = null,
    val missionId: String? = null,
    val runId: String? = null,
    val recordedAt: String = "",
    val schemaVersion: Long = 0,
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
  const swiftPublicInitializers = {
    FirestoreGatewaySignalCiphertextLayerDoc: `    public init(payloadCiphertextB64: String, payloadAADLabel: String, schemaVersion: Int) {
        self.payloadCiphertextB64 = payloadCiphertextB64
        self.payloadAADLabel = payloadAADLabel
        self.schemaVersion = schemaVersion
    }`,
    FirestoreGatewaySignalBindingDoc: `    public init(uid: String, scope: String, clientId: String? = nil, collection: String? = nil, docId: String? = nil, field: String? = nil, slotId: String? = nil, mode: String, formatVersion: Int) {
        self.uid = uid
        self.scope = scope
        self.clientId = clientId
        self.collection = collection
        self.docId = docId
        self.field = field
        self.slotId = slotId
        self.mode = mode
        self.formatVersion = formatVersion
    }`,
    FirestoreGatewaySignalAtRestWrapDoc: `    public init(recipientKind: String, recipientIdentityKeyId: String, recipientIdentityKeyB64: String, sealedContentKeyB64: String) {
        self.recipientKind = recipientKind
        self.recipientIdentityKeyId = recipientIdentityKeyId
        self.recipientIdentityKeyB64 = recipientIdentityKeyB64
        self.sealedContentKeyB64 = sealedContentKeyB64
    }`,
    FirestoreGatewaySignalKeyDeliveryDoc: `    public init(scheme: String, signalMessageType: Int? = nil, signalMessageB64: String? = nil, senderIdentityKeyId: String? = nil, ratchetEpochHint: Int? = nil, wraps: [FirestoreGatewaySignalAtRestWrapDoc]? = nil, contentKeyLength: Int? = nil) {
        self.scheme = scheme
        self.signalMessageType = signalMessageType
        self.signalMessageB64 = signalMessageB64
        self.senderIdentityKeyId = senderIdentityKeyId
        self.ratchetEpochHint = ratchetEpochHint
        self.wraps = wraps
        self.contentKeyLength = contentKeyLength
    }`,
    FirestoreGatewaySignalAtRestSenderAuthDoc: `    public init(senderIdentityKeyId: String, senderIdentityKeyB64: String, signatureB64: String, signatureVersion: Int) {
        self.senderIdentityKeyId = senderIdentityKeyId
        self.senderIdentityKeyB64 = senderIdentityKeyB64
        self.signatureB64 = signatureB64
        self.signatureVersion = signatureVersion
    }`,
    FirestoreGatewaySignalEnvelopeDoc: `    public init(signalEnvelopeFormatVersion: Int, mode: String, relayKeyVersion: Int? = nil, relayEncryption: String, ciphertextLayer: FirestoreGatewaySignalCiphertextLayerDoc, keyDelivery: FirestoreGatewaySignalKeyDeliveryDoc, binding: FirestoreGatewaySignalBindingDoc, senderAuth: FirestoreGatewaySignalAtRestSenderAuthDoc? = nil) {
        self.signalEnvelopeFormatVersion = signalEnvelopeFormatVersion
        self.mode = mode
        self.relayKeyVersion = relayKeyVersion
        self.relayEncryption = relayEncryption
        self.ciphertextLayer = ciphertextLayer
        self.keyDelivery = keyDelivery
        self.binding = binding
        self.senderAuth = senderAuth
    }`,
    FirestoreHermesGatewaySignalPrekeyBundleDoc: `    public init(version: Int, bundleId: String, identityKeyId: String, identityKeyB64: String, registrationId: Int, deviceId: Int, signedPreKeyId: Int, signedPreKeyPublicB64: String, signedPreKeySignatureB64: String, oneTimePreKeyId: Int, oneTimePreKeyPublicB64: String, kyberPreKeyId: Int, kyberPreKeyPublicB64: String, kyberPreKeySignatureB64: String, generatedAt: String) {
        self.version = version
        self.bundleId = bundleId
        self.identityKeyId = identityKeyId
        self.identityKeyB64 = identityKeyB64
        self.registrationId = registrationId
        self.deviceId = deviceId
        self.signedPreKeyId = signedPreKeyId
        self.signedPreKeyPublicB64 = signedPreKeyPublicB64
        self.signedPreKeySignatureB64 = signedPreKeySignatureB64
        self.oneTimePreKeyId = oneTimePreKeyId
        self.oneTimePreKeyPublicB64 = oneTimePreKeyPublicB64
        self.kyberPreKeyId = kyberPreKeyId
        self.kyberPreKeyPublicB64 = kyberPreKeyPublicB64
        self.kyberPreKeySignatureB64 = kyberPreKeySignatureB64
        self.generatedAt = generatedAt
    }`,
  };
  const swiftModels = Object.values(models).map((model) => {
    const source = model.swift;
    if (!source) return source;
    const structMatch = source.match(/public struct (\w+)/);
    const init = structMatch ? swiftPublicInitializers[structMatch[1]] : undefined;
    if (!init) return source;
    const closing = source.lastIndexOf("\n}");
    return `${source.slice(0, closing)}\n\n${init}${source.slice(closing)}`;
  });
  return (
    header +
    swiftModels.join("\n\n")
  );
}

function emitKotlin(domainId, models) {
  const header = `// AUTO-GENERATED by tools/schema-sync/emit/generate.mjs — do not edit.
// Domain: ${domainId}

package com.openburnbar.data.models.generated

import androidx.annotation.Keep
import com.google.firebase.firestore.IgnoreExtraProperties
import com.google.firebase.firestore.PropertyName

`;
  return (
    header +
    Object.values(models)
      .map((m) => m.kotlin)
      .join("\n\n")
  );
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

  // Every emitted file carries exactly one trailing newline — SwiftLint
  // (trailing_newline), ktlint, and eslint all enforce it on the tracked copies.
  const withFinalNewline = (text) => {
    // Collapse 2+ consecutive blank lines to one (SwiftLint vertical_whitespace).
    const collapsed = text.replace(/\n{3,}/g, "\n\n");
    return collapsed.endsWith("\n") ? collapsed : `${collapsed}\n`;
  };
  writeFileSync(tsPath, withFinalNewline(emitTypeScript(domain.id, spec.models)));
  writeFileSync(swiftPath, withFinalNewline(emitSwift(domain.id, spec.models)));
  writeFileSync(kotlinPath, withFinalNewline(emitKotlin(domain.id, spec.models)));
  console.log(`Emitted ${domain.id}: TS, Swift, Kotlin`);
}

console.log("Schema emit complete.");
