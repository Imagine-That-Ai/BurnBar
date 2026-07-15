using System;
using System.Security.Cryptography;
using System.Text;
using DomainHashPurpose = uniffi.openburnbar_domain_ffi.CloudVaultHashPurpose;

namespace OpenBurnBar.CloudSync.Crypto
{
    /// <summary>
    /// The zero-knowledge CloudVault crypto — the C# port of Swift
    /// <c>CloudVaultCrypto</c> (OpenBurnBarCore) and the TS <c>escrow.ts</c>
    /// (apps/console). Every operation is wire-compatible with those clients: a
    /// vault key wrapped by a trusted native device unwraps here, content sealed
    /// here opens natively, and the server never sees the vault key or plaintext.
    ///
    /// Fail-closed everywhere: any tag / KDF / AAD / key-length / envelope mismatch
    /// throws <see cref="CloudVaultCryptoException"/> rather than returning partial
    /// or unauthenticated data.
    ///
    /// The public seal APIs use a cryptographically random 96-bit nonce (never a
    /// caller-supplied one, to preclude nonce reuse). The <c>internal</c>
    /// nonce/ephemeral-pinned overloads exist ONLY so the byte-parity KAT can
    /// reproduce the committed CryptoKit vectors; they are not part of the public
    /// surface.
    /// </summary>
    public static class CloudVaultCrypto
    {
        public const string AesGcmAlgorithm = "AES-256-GCM";
        public const int CurrentKeyVersion = 1;
        public const int CurrentSealedTextSchemaVersion = 2;
        public const int CurrentBlobEnvelopeSchemaVersion = 2;
        public const int CurrentSealedPayloadSchemaVersion = 2;
        public const int BlobIntegrityHashVersion = 1;
        public const string BlobEnvelopeAadContext = "OpenBurnBar-CloudVaultBlob-v2";
        public const string SealedPayloadAadContext = "OpenBurnBar-CloudVaultSealedPayload-v2";
        public const string RoamingProfileAadDomain = "OpenBurnBar-RoamingProfile-v1";

        private static readonly byte[] Empty = Array.Empty<byte>();

        // ── key material ────────────────────────────────────────────────────
        public static byte[] GenerateVaultKey() => RandomNumberGenerator.GetBytes(32);

        public static string VaultKeyId(byte[] keyData)
            => DomainCoreCloudVaultBridge.VaultKeyId(keyData, () => CloudVaultLegacyCrypto.VaultKeyId(keyData));

        public static CloudVaultAadContext RoamingProfileAadContext(string uid) =>
            new(
                uid: uid,
                collection: "roaming_profile",
                docId: "current",
                field: "sealedPayload",
                schemaVersion: CurrentSealedPayloadSchemaVersion,
                purpose: RoamingProfileAadDomain);

        // ── sealText / openText (AES-256-GCM detached) ──────────────────────
        public static CloudVaultSealedText SealText(
            string text, byte[] keyData, int keyVersion = CurrentKeyVersion, CloudVaultAadContext? aadContext = null) =>
            SealText(text, keyData, keyVersion, aadContext, nonce: null);

        internal static CloudVaultSealedText SealText(
            string text, byte[] keyData, int keyVersion, CloudVaultAadContext? aadContext, byte[]? nonce)
        {
            var plaintext = Encoding.UTF8.GetBytes(text);
            var aead = aadContext?.Data ?? Empty;
            var sealed_ = SealDetached(plaintext, keyData, aead, nonce);
            return new CloudVaultSealedText(
                SchemaVersion: aadContext == null ? (int?)null : CurrentSealedTextSchemaVersion,
                Algorithm: AesGcmAlgorithm,
                KeyVersion: keyVersion,
                Nonce: EncodeBase64(sealed_.Nonce),
                Ciphertext: EncodeBase64(sealed_.Ciphertext),
                Tag: EncodeBase64(sealed_.Tag),
                Aad: aadContext?.StringValue);
        }

        public static string OpenText(CloudVaultSealedText envelope, byte[] keyData, CloudVaultAadContext? aadContext = null)
        {
            if (envelope.Algorithm != AesGcmAlgorithm)
            {
                throw CloudVaultCryptoException.InvalidEnvelope();
            }
            var nonce = DecodeBase64(envelope.Nonce);
            var ciphertext = DecodeBase64(envelope.Ciphertext);
            var tag = DecodeBase64(envelope.Tag);
            var schemaVersion = envelope.SchemaVersion ?? 1;
            if (schemaVersion != 1 && schemaVersion != CurrentSealedTextSchemaVersion)
            {
                throw CloudVaultCryptoException.InvalidEnvelope();
            }
            if (schemaVersion == CurrentSealedTextSchemaVersion)
            {
                if (aadContext == null)
                {
                    throw CloudVaultCryptoException.InvalidEnvelope();
                }
                var aead = AadData(envelope.Aad, aadContext);
                return OpenTextDetached(nonce, ciphertext, tag, keyData, aead);
            }
            return OpenTextDetached(nonce, ciphertext, tag, keyData, Empty);
        }

        // ── sealBlob / openBlob (AES-256-GCM combined + keyed integrity) ────
        public static CloudVaultBlobEnvelope SealBlob(
            byte[] data, byte[] keyData, int keyVersion = CurrentKeyVersion, CloudVaultAadContext? aadContext = null) =>
            SealBlob(data, keyData, keyVersion, aadContext, nonce: null);

        internal static CloudVaultBlobEnvelope SealBlob(
            byte[] data, byte[] keyData, int keyVersion, CloudVaultAadContext? aadContext, byte[]? nonce)
        {
            var aead = aadContext?.Data ?? Empty;
            var combined = SealCombined(data, keyData, aead, nonce);
            return new CloudVaultBlobEnvelope(
                SchemaVersion: CurrentBlobEnvelopeSchemaVersion,
                Algorithm: AesGcmAlgorithm,
                KeyVersion: keyVersion,
                PlaintextSha256: null,
                PlaintextHmac: BlobPlaintextHmac(data, keyData),
                IntegrityHashVersion: BlobIntegrityHashVersion,
                SealedBoxBase64: EncodeBase64(combined),
                Aad: aadContext?.StringValue ?? BlobEnvelopeAadContext);
        }

        public static byte[] OpenBlob(CloudVaultBlobEnvelope envelope, byte[] keyData, CloudVaultAadContext? aadContext = null)
        {
            if (envelope.Algorithm != AesGcmAlgorithm)
            {
                throw CloudVaultCryptoException.InvalidEnvelope();
            }
            var combined = DecodeBase64(envelope.SealedBoxBase64);
            byte[] plaintext;
            switch (envelope.SchemaVersion)
            {
                case 1:
                    plaintext = OpenCombined(combined, keyData, Empty);
                    if (envelope.PlaintextSha256 == null || Sha256Hex(plaintext) != envelope.PlaintextSha256)
                    {
                        throw CloudVaultCryptoException.InvalidEnvelope();
                    }
                    break;
                case CurrentBlobEnvelopeSchemaVersion:
                    if (envelope.Aad == BlobEnvelopeAadContext)
                    {
                        plaintext = OpenCombined(combined, keyData, Empty);
                    }
                    else
                    {
                        if (aadContext == null)
                        {
                            throw CloudVaultCryptoException.InvalidEnvelope();
                        }
                        plaintext = OpenCombined(combined, keyData, AadData(envelope.Aad, aadContext));
                    }
                    if (envelope.IntegrityHashVersion != BlobIntegrityHashVersion
                        || envelope.PlaintextHmac == null
                        || !CloudVaultLegacyCrypto.ConstantTimeEquals(BlobPlaintextHmac(plaintext, keyData), envelope.PlaintextHmac))
                    {
                        throw CloudVaultCryptoException.InvalidEnvelope();
                    }
                    break;
                default:
                    throw CloudVaultCryptoException.InvalidEnvelope();
            }
            return plaintext;
        }

        // ── sealPayload / openPayload (AES-256-GCM combined + metadata AAD) ──
        public static CloudVaultSealedPayload SealPayload(
            byte[] data, byte[] keyData, string vaultKeyId, int keyVersion = CurrentKeyVersion, CloudVaultAadContext? aadContext = null) =>
            SealPayload(data, keyData, vaultKeyId, keyVersion, aadContext, nonce: null);

        internal static CloudVaultSealedPayload SealPayload(
            byte[] data, byte[] keyData, string vaultKeyId, int keyVersion, CloudVaultAadContext? aadContext, byte[]? nonce)
        {
            var envAad = aadContext?.StringValue ?? SealedPayloadAadContext;
            var aead = SealedPayloadAad(AesGcmAlgorithm, keyVersion, vaultKeyId, aadContext);
            var combined = SealCombined(data, keyData, aead, nonce);
            return new CloudVaultSealedPayload(
                SchemaVersion: CurrentSealedPayloadSchemaVersion,
                Algorithm: AesGcmAlgorithm,
                KeyVersion: keyVersion,
                VaultKeyId: vaultKeyId,
                SealedBoxBase64: EncodeBase64(combined),
                Aad: envAad);
        }

        public static byte[] OpenPayload(CloudVaultSealedPayload envelope, byte[] keyData, CloudVaultAadContext? aadContext = null)
        {
            if (envelope.Algorithm != AesGcmAlgorithm || envelope.VaultKeyId != VaultKeyId(keyData))
            {
                throw CloudVaultCryptoException.InvalidEnvelope();
            }
            var combined = DecodeBase64(envelope.SealedBoxBase64);
            switch (envelope.SchemaVersion)
            {
                case 1:
                    return OpenCombined(combined, keyData, Empty);
                case CurrentSealedPayloadSchemaVersion:
                    if (envelope.Aad == SealedPayloadAadContext)
                    {
                        return OpenCombined(
                            combined, keyData, SealedPayloadAad(envelope.Algorithm, envelope.KeyVersion, envelope.VaultKeyId, null));
                    }
                    if (aadContext == null)
                    {
                        throw CloudVaultCryptoException.InvalidEnvelope();
                    }
                    return OpenCombined(combined, keyData, AadData(envelope.Aad, aadContext));
                default:
                    throw CloudVaultCryptoException.InvalidEnvelope();
            }
        }

        public static CloudVaultSealedPayload SealRoamingProfile(
            byte[] payloadJson, byte[] keyData, string uid, int keyVersion = CurrentKeyVersion) =>
            SealPayload(payloadJson, keyData, VaultKeyId(keyData), keyVersion, RoamingProfileAadContext(uid));

        public static byte[] OpenRoamingProfile(CloudVaultSealedPayload envelope, byte[] keyData, string uid) =>
            OpenPayload(envelope, keyData, RoamingProfileAadContext(uid));

        private static byte[] SealedPayloadAad(string algorithm, int keyVersion, string vaultKeyId, CloudVaultAadContext? aadContext) =>
            CloudVaultLegacyCrypto.SealedPayloadAad(algorithm, keyVersion, vaultKeyId, aadContext);

        // ── escrow key-wrap (P-256 ECDH + HKDF + AES-256-GCM) ───────────────
        public static byte[] WrapVaultKey(byte[] keyData, byte[] recipientPublicKeyX963)
        {
            var (scalar, _) = P256KeyAgreement.GenerateEphemeral();
            return WrapVaultKey(keyData, recipientPublicKeyX963, scalar, nonce: null);
        }

        internal static byte[] WrapVaultKey(byte[] keyData, byte[] recipientPublicKeyX963, byte[] ephemeralScalar, byte[]? nonce)
        {
            CloudVaultLegacyCrypto.RequireVaultKey(keyData);
            DomainCoreCloudVaultBridge.ValidateP256PublicKey(
                recipientPublicKeyX963,
                () => P256KeyAgreement.ValidateX963(recipientPublicKeyX963));
            var ephemeralPublic = P256KeyAgreement.PublicX963FromScalar(ephemeralScalar);
            var shared = P256KeyAgreement.SharedSecretX(ephemeralScalar, recipientPublicKeyX963);
            var selectedNonce = nonce ?? RandomNumberGenerator.GetBytes(12);
            try
            {
                return DomainCoreCloudVaultBridge.EscrowSeal(
                    keyData,
                    ephemeralPublic,
                    shared,
                    selectedNonce,
                () => CloudVaultLegacyCrypto.EscrowSeal(keyData, ephemeralPublic, shared, selectedNonce));
            }
            finally
            {
                CryptographicOperations.ZeroMemory(shared);
            }
        }

        public static byte[] UnwrapVaultKey(byte[] ciphertext, byte[] recipientPrivateKeyRaw)
        {
            var parts = DomainCoreCloudVaultBridge.EscrowSplitWire(
                ciphertext,
                () => CloudVaultLegacyCrypto.EscrowSplitWire(ciphertext));
            var shared = P256KeyAgreement.SharedSecretX(recipientPrivateKeyRaw, parts.EphemeralPublicKey);
            byte[] keyData;
            try
            {
                keyData = DomainCoreCloudVaultBridge.EscrowOpen(
                    ciphertext,
                    shared,
                    () => CloudVaultLegacyCrypto.EscrowOpen(parts.AesGcmCombined, shared));
            }
            finally
            {
                CryptographicOperations.ZeroMemory(shared);
            }
            if (keyData.Length != 32)
            {
                throw CloudVaultCryptoException.InvalidKeyLength();
            }
            return keyData;
        }

        // ── recovery wrap (HKDF(recovery key) + AES-256-GCM) ────────────────
        public static byte[] DeriveRecoveryWrappingKey(string recoveryKey)
            => DomainCoreCloudVaultBridge.RecoveryWrappingKey(
                recoveryKey,
                () => CloudVaultLegacyCrypto.DeriveRecoveryWrappingKey(recoveryKey));

        public static (string WrappedVaultKeyBase64, string VerificationHash) WrapVaultKeyWithRecovery(
            byte[] vaultKey, string recoveryKey) =>
            WrapVaultKeyWithRecovery(vaultKey, recoveryKey, nonce: null);

        internal static (string WrappedVaultKeyBase64, string VerificationHash) WrapVaultKeyWithRecovery(
            byte[] vaultKey, string recoveryKey, byte[]? nonce)
        {
            CloudVaultLegacyCrypto.RequireVaultKey(vaultKey);
            var selectedNonce = nonce ?? RandomNumberGenerator.GetBytes(12);
            var wrapped = DomainCoreCloudVaultBridge.RecoveryWrapVaultKey(
                vaultKey,
                recoveryKey,
                selectedNonce,
                () => CloudVaultLegacyCrypto.RecoveryWrapVaultKey(vaultKey, recoveryKey, selectedNonce));
            return (EncodeBase64(wrapped.Combined), wrapped.VerificationHash);
        }

        public static byte[] UnwrapVaultKeyWithRecovery(string wrappedVaultKeyBase64, string recoveryKey)
        {
            var combined = DecodeBase64(wrappedVaultKeyBase64);
            var keyData = DomainCoreCloudVaultBridge.RecoveryOpenVaultKey(
                combined,
                recoveryKey,
                () => CloudVaultLegacyCrypto.RecoveryOpenVaultKey(combined, recoveryKey));
            if (keyData.Length != 32)
            {
                throw CloudVaultCryptoException.InvalidKeyLength();
            }
            return keyData;
        }

        public static string RecoveryVerificationHash(string recoveryKey) =>
            DomainCoreCloudVaultBridge.RecoveryVerificationHash(
                recoveryKey,
                () => CloudVaultLegacyCrypto.RecoveryVerificationHash(recoveryKey));

        // ── vault-keyed HMAC hashes ─────────────────────────────────────────
        public static string BlobPlaintextHmac(byte[] data, byte[] keyData) =>
            DomainCoreCloudVaultBridge.KeyedHashHex(
                data,
                keyData,
                DomainHashPurpose.BlobIntegrity,
                () => CloudVaultLegacyCrypto.KeyedHmacHex(data, keyData, "blob-integrity"));

        public static string SessionBodyHash(byte[] data, byte[] keyData) =>
            DomainCoreCloudVaultBridge.KeyedHashHex(
                data,
                keyData,
                DomainHashPurpose.SessionBody,
                () => CloudVaultLegacyCrypto.KeyedHmacHex(data, keyData, "session-body"));

        public static string SessionBodyHash(string text, byte[] keyData) =>
            SessionBodyHash(Encoding.UTF8.GetBytes(text), keyData);

        public static string SessionChunkHash(string chunk, byte[] keyData) =>
            DomainCoreCloudVaultBridge.KeyedHashHex(
                Encoding.UTF8.GetBytes(chunk),
                keyData,
                DomainHashPurpose.SessionChunk,
                () => CloudVaultLegacyCrypto.KeyedHmacHex(Encoding.UTF8.GetBytes(chunk), keyData, "session-chunk"));

        public static string ProjectMemoryContentHash(byte[] data, byte[] keyData) =>
            DomainCoreCloudVaultBridge.KeyedHashHex(
                data,
                keyData,
                DomainHashPurpose.ProjectMemoryContent,
                () => CloudVaultLegacyCrypto.KeyedHmacHex(data, keyData, "project-memory-content"));

        /// <summary>
        /// Vault-keyed HMAC for Pensieve/memory opaque doc ids — parity with Swift
        /// <c>pensieveSlugHmac</c> (HKDF info <c>pensieve-dedup:slug</c>).
        /// </summary>
        public static string PensieveSlugHmac(string slug, byte[] keyData) =>
            CloudVaultLegacyCrypto.PensieveSlugHmac(slug, keyData);

        // ── hashing helpers ─────────────────────────────────────────────────
        public static string Sha256Hex(byte[] data) =>
            DomainCoreCloudVaultBridge.Sha256Hex(data, () => CloudVaultLegacyCrypto.Sha256Hex(data));

        public static string Sha256Hex(string text) => Sha256Hex(Encoding.UTF8.GetBytes(text));

        // ── internals ───────────────────────────────────────────────────────
        private static byte[] AadData(string? envelopeAad, CloudVaultAadContext context) =>
            AadData(envelopeAad, context, CloudVaultV1AadRejection.DefaultEnabled);

        internal static byte[] AadData(string? envelopeAad, CloudVaultAadContext context, bool rejectLegacyV1)
            => DomainCoreCloudVaultBridge.ResolveAad(
                envelopeAad ?? string.Empty,
                context,
                rejectLegacyV1,
                () => CloudVaultLegacyCrypto.AadData(envelopeAad, context, rejectLegacyV1));

        private static (byte[] Nonce, byte[] Ciphertext, byte[] Tag, byte[] Combined) SealDetached(
            byte[] plaintext,
            byte[] keyData,
            byte[] aad,
            byte[]? nonce)
        {
            var resolvedNonce = nonce ?? RandomNumberGenerator.GetBytes(CloudVaultLegacyCrypto.NonceLength);
            return DomainCoreCloudVaultBridge.SealDetached(
                plaintext,
                keyData,
                resolvedNonce,
                aad,
                () => CloudVaultLegacyCrypto.SealDetached(plaintext, keyData, aad, resolvedNonce));
        }

        private static byte[] SealCombined(byte[] plaintext, byte[] keyData, byte[] aad, byte[]? nonce)
        {
            var resolvedNonce = nonce ?? RandomNumberGenerator.GetBytes(CloudVaultLegacyCrypto.NonceLength);
            return DomainCoreCloudVaultBridge.SealCombined(
                plaintext,
                keyData,
                resolvedNonce,
                aad,
                () => CloudVaultLegacyCrypto.SealCombined(plaintext, keyData, aad, resolvedNonce));
        }

        private static byte[] OpenCombined(byte[] combined, byte[] keyData, byte[] aad) =>
            DomainCoreCloudVaultBridge.OpenCombined(
                combined,
                keyData,
                aad,
                () => CloudVaultLegacyCrypto.OpenCombined(combined, keyData, aad));

        private static string OpenTextDetached(
            byte[] nonce,
            byte[] ciphertext,
            byte[] tag,
            byte[] keyData,
            byte[] aad) =>
            DomainCoreCloudVaultBridge.OpenTextDetached(
                nonce,
                ciphertext,
                tag,
                keyData,
                aad,
                () => CloudVaultLegacyCrypto.OpenTextDetached(nonce, ciphertext, tag, keyData, aad));

        private static string EncodeBase64(byte[] data) =>
            DomainCoreCloudVaultBridge.Base64Encode(data, () => CloudVaultLegacyCrypto.EncodeBase64(data));

        private static byte[] DecodeBase64(string value)
        {
            return DomainCoreCloudVaultBridge.Base64Decode(value, () => CloudVaultLegacyCrypto.DecodeBase64(value));
        }

    }
}
