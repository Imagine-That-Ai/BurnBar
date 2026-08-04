using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace OpenBurnBar.CloudSync.Models;

// Port of OpenBurnBarFirestoreModels/HermesGatewayModels.swift — Domain: hermes-gateway.
// This is the E2EE-carrying surface: relay / ratchet / signal envelopes wrap
// ciphertext, and Event / Message docs carry an OPTIONAL plaintext `text` that
// must be absent whenever an encrypted envelope is required (see Security/E2EEWriteGuard).

public sealed record FirestoreHermesGatewayModelOptionDoc
{
    [JsonPropertyName("providerId")] public required string ProviderId { get; init; }
    [JsonPropertyName("providerName")] public required string ProviderName { get; init; }
    [JsonPropertyName("modelId")] public required string ModelId { get; init; }
    [JsonPropertyName("displayName")] public required string DisplayName { get; init; }
}

public sealed record FirestoreGatewayRelayEnvelopeDoc
{
    [JsonPropertyName("payloadCiphertext")] public required string PayloadCiphertext { get; init; }
    [JsonPropertyName("wrappedKey")] public required string WrappedKey { get; init; }
    [JsonPropertyName("relayEncryption")] public required string RelayEncryption { get; init; }
    [JsonPropertyName("relayKeyVersion")] public required long RelayKeyVersion { get; init; }
    [JsonPropertyName("enc")] public string? Enc { get; init; }
    [JsonPropertyName("senderPublicKey")] public string? SenderPublicKey { get; init; }
}

public sealed record FirestoreGatewayRatchetHeaderDoc
{
    [JsonPropertyName("version")] public required long Version { get; init; }
    [JsonPropertyName("algorithm")] public required string Algorithm { get; init; }
    [JsonPropertyName("sessionID")] public required string SessionID { get; init; }
    [JsonPropertyName("senderDeviceID")] public required string SenderDeviceID { get; init; }
    [JsonPropertyName("receiverDeviceID")] public required string ReceiverDeviceID { get; init; }
    [JsonPropertyName("ratchetPublicKeyBase64")] public required string RatchetPublicKeyBase64 { get; init; }
    [JsonPropertyName("previousChainLength")] public required long PreviousChainLength { get; init; }
    [JsonPropertyName("messageNumber")] public required long MessageNumber { get; init; }
    [JsonPropertyName("epoch")] public required long Epoch { get; init; }
}

public sealed record FirestoreGatewayRatchetEnvelopeDoc
{
    [JsonPropertyName("header")] public required FirestoreGatewayRatchetHeaderDoc Header { get; init; }
    [JsonPropertyName("ciphertextBase64")] public required string CiphertextBase64 { get; init; }
}

public sealed record FirestoreGatewaySignalCiphertextLayerDoc
{
    [JsonPropertyName("payloadCiphertextB64")] public required string PayloadCiphertextB64 { get; init; }
    [JsonPropertyName("payloadAADLabel")] public required string PayloadAADLabel { get; init; }
    [JsonPropertyName("schemaVersion")] public required long SchemaVersion { get; init; }
}

public sealed record FirestoreGatewaySignalBindingDoc
{
    [JsonPropertyName("uid")] public required string Uid { get; init; }
    [JsonPropertyName("scope")] public required string Scope { get; init; }
    [JsonPropertyName("clientId")] public string? ClientId { get; init; }
    [JsonPropertyName("collection")] public string? Collection { get; init; }
    [JsonPropertyName("docId")] public string? DocId { get; init; }
    [JsonPropertyName("field")] public string? Field { get; init; }
    [JsonPropertyName("slotId")] public string? SlotId { get; init; }
    [JsonPropertyName("mode")] public required string Mode { get; init; }
    [JsonPropertyName("formatVersion")] public required long FormatVersion { get; init; }
}

public sealed record FirestoreGatewaySignalAtRestWrapDoc
{
    [JsonPropertyName("recipientKind")] public required string RecipientKind { get; init; }
    [JsonPropertyName("recipientIdentityKeyId")] public required string RecipientIdentityKeyId { get; init; }
    [JsonPropertyName("recipientIdentityKeyB64")] public required string RecipientIdentityKeyB64 { get; init; }
    [JsonPropertyName("sealedContentKeyB64")] public required string SealedContentKeyB64 { get; init; }
}

public sealed record FirestoreGatewaySignalKeyDeliveryDoc
{
    [JsonPropertyName("scheme")] public required string Scheme { get; init; }
    [JsonPropertyName("signalMessageType")] public long? SignalMessageType { get; init; }
    [JsonPropertyName("signalMessageB64")] public string? SignalMessageB64 { get; init; }
    [JsonPropertyName("senderIdentityKeyId")] public string? SenderIdentityKeyId { get; init; }
    [JsonPropertyName("ratchetEpochHint")] public long? RatchetEpochHint { get; init; }
    [JsonPropertyName("wraps")] public IReadOnlyList<FirestoreGatewaySignalAtRestWrapDoc>? Wraps { get; init; }
    [JsonPropertyName("contentKeyLength")] public long? ContentKeyLength { get; init; }
}

public sealed record FirestoreGatewaySignalEnvelopeDoc
{
    [JsonPropertyName("signalEnvelopeFormatVersion")] public required long SignalEnvelopeFormatVersion { get; init; }
    [JsonPropertyName("mode")] public required string Mode { get; init; }
    [JsonPropertyName("relayKeyVersion")] public long? RelayKeyVersion { get; init; }
    [JsonPropertyName("relayEncryption")] public required string RelayEncryption { get; init; }
    [JsonPropertyName("ciphertextLayer")] public required FirestoreGatewaySignalCiphertextLayerDoc CiphertextLayer { get; init; }
    [JsonPropertyName("keyDelivery")] public required FirestoreGatewaySignalKeyDeliveryDoc KeyDelivery { get; init; }
    [JsonPropertyName("senderAuth")] public FirestoreGatewaySignalAtRestSenderAuthDoc? SenderAuth { get; init; }
    [JsonPropertyName("binding")] public required FirestoreGatewaySignalBindingDoc Binding { get; init; }
}

public sealed record FirestoreGatewaySignalAtRestSenderAuthDoc
{
    [JsonPropertyName("signatureVersion")] public required long SignatureVersion { get; init; }
    [JsonPropertyName("senderIdentityKeyId")] public required string SenderIdentityKeyId { get; init; }
    [JsonPropertyName("senderIdentityKeyB64")] public required string SenderIdentityKeyB64 { get; init; }
    [JsonPropertyName("signatureB64")] public required string SignatureB64 { get; init; }
}

public sealed record FirestoreHermesGatewaySignalPrekeyBundleDoc
{
    [JsonPropertyName("version")] public required long Version { get; init; }
    [JsonPropertyName("bundleId")] public required string BundleId { get; init; }
    [JsonPropertyName("identityKeyId")] public required string IdentityKeyId { get; init; }
    [JsonPropertyName("identityKeyB64")] public required string IdentityKeyB64 { get; init; }
    [JsonPropertyName("registrationId")] public required long RegistrationId { get; init; }
    [JsonPropertyName("deviceId")] public required long DeviceId { get; init; }
    [JsonPropertyName("signedPreKeyId")] public required long SignedPreKeyId { get; init; }
    [JsonPropertyName("signedPreKeyPublicB64")] public required string SignedPreKeyPublicB64 { get; init; }
    [JsonPropertyName("signedPreKeySignatureB64")] public required string SignedPreKeySignatureB64 { get; init; }
    [JsonPropertyName("oneTimePreKeyId")] public required long OneTimePreKeyId { get; init; }
    [JsonPropertyName("oneTimePreKeyPublicB64")] public required string OneTimePreKeyPublicB64 { get; init; }
    [JsonPropertyName("kyberPreKeyId")] public required long KyberPreKeyId { get; init; }
    [JsonPropertyName("kyberPreKeyPublicB64")] public required string KyberPreKeyPublicB64 { get; init; }
    [JsonPropertyName("kyberPreKeySignatureB64")] public required string KyberPreKeySignatureB64 { get; init; }
    [JsonPropertyName("generatedAt")] public required string GeneratedAt { get; init; }
}

public sealed record FirestoreHermesGatewayClientDoc
{
    [JsonPropertyName("id")] public required string Id { get; init; }
    [JsonPropertyName("uid")] public required string Uid { get; init; }
    [JsonPropertyName("displayName")] public required string DisplayName { get; init; }
    [JsonPropertyName("status")] public required string Status { get; init; }
    [JsonPropertyName("tokenHash")] public required string TokenHash { get; init; }
    [JsonPropertyName("tokenPreview")] public required string TokenPreview { get; init; }
    [JsonPropertyName("agentClientSigningPublicKeyBase64")] public string? AgentClientSigningPublicKeyBase64 { get; init; }
    [JsonPropertyName("agentClientSigningKeyId")] public string? AgentClientSigningKeyId { get; init; }
    [JsonPropertyName("popRequired")] public bool? PopRequired { get; init; }
    [JsonPropertyName("popVersion")] public long? PopVersion { get; init; }
    [JsonPropertyName("scopes")] public required IReadOnlyList<string> Scopes { get; init; }
    [JsonPropertyName("homeDestinationId")] public required string HomeDestinationId { get; init; }
    [JsonPropertyName("expiresAt")] public string? ExpiresAt { get; init; }
    [JsonPropertyName("rotatedAt")] public string? RotatedAt { get; init; }
    [JsonPropertyName("lastSeenAt")] public string? LastSeenAt { get; init; }
    [JsonPropertyName("agentRelayPublicKey")] public string? AgentRelayPublicKey { get; init; }
    [JsonPropertyName("agentRelayKeyVersion")] public long? AgentRelayKeyVersion { get; init; }
    [JsonPropertyName("agentRelayEncryption")] public string? AgentRelayEncryption { get; init; }
    [JsonPropertyName("agentSupportsRelayEnvelopeVersions")] public IReadOnlyList<long>? AgentSupportsRelayEnvelopeVersions { get; init; }
    [JsonPropertyName("agentPreferredRelayEnvelopeVersion")] public long? AgentPreferredRelayEnvelopeVersion { get; init; }
    [JsonPropertyName("agentSupportsHpkeV3")] public bool? AgentSupportsHpkeV3 { get; init; }
    [JsonPropertyName("agentSupportsSignalEnvelope")] public bool? AgentSupportsSignalEnvelope { get; init; }
    [JsonPropertyName("agentSignalPrekeyBundle")] public FirestoreHermesGatewaySignalPrekeyBundleDoc? AgentSignalPrekeyBundle { get; init; }
    [JsonPropertyName("agentPlatform")] public string? AgentPlatform { get; init; }
    [JsonPropertyName("agentAppBuild")] public string? AgentAppBuild { get; init; }
    [JsonPropertyName("phoneRelayPublicKey")] public string? PhoneRelayPublicKey { get; init; }
    [JsonPropertyName("phoneRelayKeyVersion")] public long? PhoneRelayKeyVersion { get; init; }
    [JsonPropertyName("phoneRelayEncryption")] public string? PhoneRelayEncryption { get; init; }
    [JsonPropertyName("phoneSupportsRelayEnvelopeVersions")] public IReadOnlyList<long>? PhoneSupportsRelayEnvelopeVersions { get; init; }
    [JsonPropertyName("phonePreferredRelayEnvelopeVersion")] public long? PhonePreferredRelayEnvelopeVersion { get; init; }
    [JsonPropertyName("phoneSupportsHpkeV3")] public bool? PhoneSupportsHpkeV3 { get; init; }
    [JsonPropertyName("phoneSupportsSignalEnvelope")] public bool? PhoneSupportsSignalEnvelope { get; init; }
    [JsonPropertyName("phoneSignalPrekeyBundle")] public FirestoreHermesGatewaySignalPrekeyBundleDoc? PhoneSignalPrekeyBundle { get; init; }
    [JsonPropertyName("phonePlatform")] public string? PhonePlatform { get; init; }
    [JsonPropertyName("phoneAppBuild")] public string? PhoneAppBuild { get; init; }
    [JsonPropertyName("agentRatchetIdentityPublicKey")] public string? AgentRatchetIdentityPublicKey { get; init; }
    [JsonPropertyName("agentRatchetSigningPublicKey")] public string? AgentRatchetSigningPublicKey { get; init; }
    [JsonPropertyName("agentRatchetSignedPreKeyPublicKey")] public string? AgentRatchetSignedPreKeyPublicKey { get; init; }
    [JsonPropertyName("agentRatchetSignedPreKeyId")] public string? AgentRatchetSignedPreKeyId { get; init; }
    [JsonPropertyName("agentRatchetSignedPreKeySignature")] public string? AgentRatchetSignedPreKeySignature { get; init; }
    [JsonPropertyName("agentSupportsRatchetV1")] public bool? AgentSupportsRatchetV1 { get; init; }
    [JsonPropertyName("phoneRatchetIdentityPublicKey")] public string? PhoneRatchetIdentityPublicKey { get; init; }
    [JsonPropertyName("phoneRatchetSigningPublicKey")] public string? PhoneRatchetSigningPublicKey { get; init; }
    [JsonPropertyName("phoneRatchetSignedPreKeyPublicKey")] public string? PhoneRatchetSignedPreKeyPublicKey { get; init; }
    [JsonPropertyName("phoneRatchetSignedPreKeyId")] public string? PhoneRatchetSignedPreKeyId { get; init; }
    [JsonPropertyName("phoneRatchetSignedPreKeySignature")] public string? PhoneRatchetSignedPreKeySignature { get; init; }
    [JsonPropertyName("phoneSupportsRatchetV1")] public bool? PhoneSupportsRatchetV1 { get; init; }
    [JsonPropertyName("supportsRatchetV1")] public bool? SupportsRatchetV1 { get; init; }
    [JsonPropertyName("supportsRelayEnvelopeVersions")] public IReadOnlyList<long>? SupportsRelayEnvelopeVersions { get; init; }
    [JsonPropertyName("preferredRelayEnvelopeVersion")] public long? PreferredRelayEnvelopeVersion { get; init; }
    [JsonPropertyName("supportsHpkeV3")] public bool? SupportsHpkeV3 { get; init; }
    [JsonPropertyName("supportsSignalEnvelope")] public bool? SupportsSignalEnvelope { get; init; }
    [JsonPropertyName("relayCapable")] public bool? RelayCapable { get; init; }
    [JsonPropertyName("runtimeModelId")] public string? RuntimeModelId { get; init; }
    [JsonPropertyName("runtimeProviderId")] public string? RuntimeProviderId { get; init; }
    [JsonPropertyName("runtimeModelOptions")] public IReadOnlyList<FirestoreHermesGatewayModelOptionDoc>? RuntimeModelOptions { get; init; }
    [JsonPropertyName("runtimeUpdatedAt")] public string? RuntimeUpdatedAt { get; init; }
    [JsonPropertyName("agentVersion")] public string? AgentVersion { get; init; }
    [JsonPropertyName("pendingModelId")] public string? PendingModelId { get; init; }
    [JsonPropertyName("pendingModelRequestedAt")] public string? PendingModelRequestedAt { get; init; }
    [JsonPropertyName("oversightMode")] public string? OversightMode { get; init; }
    [JsonPropertyName("revokedAt")] public string? RevokedAt { get; init; }
    [JsonPropertyName("createdAt")] public required string CreatedAt { get; init; }
    [JsonPropertyName("updatedAt")] public required string UpdatedAt { get; init; }
    [JsonPropertyName("schemaVersion")] public required long SchemaVersion { get; init; }
}

public sealed record FirestoreHermesGatewayApprovalDoc
{
    [JsonPropertyName("id")] public required string Id { get; init; }
    [JsonPropertyName("clientId")] public required string ClientId { get; init; }
    [JsonPropertyName("destinationId")] public required string DestinationId { get; init; }
    [JsonPropertyName("actionId")] public required string ActionId { get; init; }
    [JsonPropertyName("toolName")] public string? ToolName { get; init; }
    [JsonPropertyName("summary")] public required string Summary { get; init; }
    [JsonPropertyName("status")] public required string Status { get; init; }
    [JsonPropertyName("requestedAt")] public required string RequestedAt { get; init; }
    [JsonPropertyName("expiresAt")] public required string ExpiresAt { get; init; }
    [JsonPropertyName("respondedAt")] public string? RespondedAt { get; init; }
    [JsonPropertyName("approvedByDeviceId")] public string? ApprovedByDeviceId { get; init; }
    [JsonPropertyName("schemaVersion")] public required long SchemaVersion { get; init; }
}

public sealed record FirestoreHermesGatewayDestinationDoc
{
    [JsonPropertyName("id")] public required string Id { get; init; }
    [JsonPropertyName("displayName")] public required string DisplayName { get; init; }
    [JsonPropertyName("kind")] public required string Kind { get; init; }
    [JsonPropertyName("status")] public required string Status { get; init; }
    [JsonPropertyName("isDefault")] public required bool IsDefault { get; init; }
    [JsonPropertyName("createdAt")] public required string CreatedAt { get; init; }
    [JsonPropertyName("updatedAt")] public required string UpdatedAt { get; init; }
    [JsonPropertyName("schemaVersion")] public required long SchemaVersion { get; init; }
}

public sealed record FirestoreHermesGatewayEventDoc
{
    [JsonPropertyName("id")] public required string Id { get; init; }
    [JsonPropertyName("sequence")] public required long Sequence { get; init; }
    [JsonPropertyName("kind")] public required string Kind { get; init; }
    [JsonPropertyName("destinationId")] public required string DestinationId { get; init; }
    [JsonPropertyName("targetClientId")] public string? TargetClientId { get; init; }
    [JsonPropertyName("threadId")] public string? ThreadId { get; init; }
    [JsonPropertyName("senderId")] public required string SenderId { get; init; }
    [JsonPropertyName("senderDisplayName")] public string? SenderDisplayName { get; init; }
    [JsonPropertyName("text")] public string? Text { get; init; }
    [JsonPropertyName("modelId")] public string? ModelId { get; init; }
    [JsonPropertyName("attachmentIds")] public required IReadOnlyList<string> AttachmentIds { get; init; }
    [JsonPropertyName("relayEnvelope")] public FirestoreGatewayRelayEnvelopeDoc? RelayEnvelope { get; init; }
    [JsonPropertyName("ratchetEnvelope")] public FirestoreGatewayRatchetEnvelopeDoc? RatchetEnvelope { get; init; }
    [JsonPropertyName("signalEnvelope")] public FirestoreGatewaySignalEnvelopeDoc? SignalEnvelope { get; init; }
    [JsonPropertyName("createdAt")] public required string CreatedAt { get; init; }
    [JsonPropertyName("schemaVersion")] public required long SchemaVersion { get; init; }
}

public sealed record FirestoreHermesGatewayMessageDoc
{
    [JsonPropertyName("id")] public required string Id { get; init; }
    [JsonPropertyName("clientId")] public required string ClientId { get; init; }
    [JsonPropertyName("kind")] public required string Kind { get; init; }
    [JsonPropertyName("destinationId")] public required string DestinationId { get; init; }
    [JsonPropertyName("threadId")] public string? ThreadId { get; init; }
    [JsonPropertyName("replyToEventId")] public string? ReplyToEventId { get; init; }
    [JsonPropertyName("text")] public string? Text { get; init; }
    [JsonPropertyName("attachmentIds")] public required IReadOnlyList<string> AttachmentIds { get; init; }
    [JsonPropertyName("relayEnvelope")] public FirestoreGatewayRelayEnvelopeDoc? RelayEnvelope { get; init; }
    [JsonPropertyName("ratchetEnvelope")] public FirestoreGatewayRatchetEnvelopeDoc? RatchetEnvelope { get; init; }
    [JsonPropertyName("signalEnvelope")] public FirestoreGatewaySignalEnvelopeDoc? SignalEnvelope { get; init; }
    [JsonPropertyName("createdAt")] public required string CreatedAt { get; init; }
    [JsonPropertyName("schemaVersion")] public required long SchemaVersion { get; init; }
}

public sealed record FirestoreHermesGatewayAttachmentManifestDoc
{
    [JsonPropertyName("id")] public required string Id { get; init; }
    [JsonPropertyName("clientId")] public required string ClientId { get; init; }
    [JsonPropertyName("destinationId")] public string? DestinationId { get; init; }
    [JsonPropertyName("fileName")] public string? FileName { get; init; }
    [JsonPropertyName("contentType")] public required string ContentType { get; init; }
    [JsonPropertyName("byteCount")] public required long ByteCount { get; init; }
    [JsonPropertyName("storagePath")] public required string StoragePath { get; init; }
    [JsonPropertyName("status")] public required string Status { get; init; }
    [JsonPropertyName("relayEnvelope")] public FirestoreGatewayRelayEnvelopeDoc? RelayEnvelope { get; init; }
    [JsonPropertyName("ratchetEnvelope")] public FirestoreGatewayRatchetEnvelopeDoc? RatchetEnvelope { get; init; }
    [JsonPropertyName("signalEnvelope")] public FirestoreGatewaySignalEnvelopeDoc? SignalEnvelope { get; init; }
    [JsonPropertyName("createdAt")] public required string CreatedAt { get; init; }
    [JsonPropertyName("updatedAt")] public string? UpdatedAt { get; init; }
    [JsonPropertyName("expiresAt")] public required string ExpiresAt { get; init; }
    [JsonPropertyName("uploadedAt")] public string? UploadedAt { get; init; }
    [JsonPropertyName("finalizedAt")] public string? FinalizedAt { get; init; }
    [JsonPropertyName("sha256")] public string? Sha256 { get; init; }
    [JsonPropertyName("storageGeneration")] public string? StorageGeneration { get; init; }
    [JsonPropertyName("schemaVersion")] public required long SchemaVersion { get; init; }
}
