using System;
using System.Security.Cryptography;
using System.Text;

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

        private const string EscrowHkdfInfo = "OpenBurnBar-Escrow-v1";
        private const string HmacSalt = "OpenBurnBar-CloudVault-HMAC-Salt-v1";
        private const string HmacInfoPrefix = "OpenBurnBar-CloudVault-HMAC-v1";
        private const string RecoverySalt = "OpenBurnBar-Recovery-Salt-v1";
        private const string RecoveryWrapInfo = "OpenBurnBar-Recovery-Wrap-v1";

        private static readonly byte[] Empty = Array.Empty<byte>();

        // ── key material ────────────────────────────────────────────────────
        public static byte[] GenerateVaultKey() => RandomNumberGenerator.GetBytes(32);

        public static string VaultKeyId(byte[] keyData)
        {
            RequireVaultKey(keyData);
            return "v1_" + Sha256Hex(keyData).Substring(0, 32);
        }

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
            var sealed_ = AesGcmBox.SealDetached(plaintext, keyData, aead, nonce);
            return new CloudVaultSealedText(
                SchemaVersion: aadContext == null ? (int?)null : CurrentSealedTextSchemaVersion,
                Algorithm: AesGcmAlgorithm,
                KeyVersion: keyVersion,
                Nonce: Convert.ToBase64String(sealed_.Nonce),
                Ciphertext: Convert.ToBase64String(sealed_.Ciphertext),
                Tag: Convert.ToBase64String(sealed_.Tag),
                Aad: aadContext?.StringValue);
        }

        public static string OpenText(CloudVaultSealedText envelope, byte[] keyData, CloudVaultAadContext? aadContext = null)
        {
            var data = OpenTextData(envelope, keyData, aadContext);
            try
            {
                // Strict UTF-8 decode: reject non-UTF-8 plaintext (matches Swift
                // String(data:encoding:.utf8) returning nil -> invalidEnvelope).
                return new UTF8Encoding(false, true).GetString(data);
            }
            catch (DecoderFallbackException ex)
            {
                throw CloudVaultCryptoException.InvalidEnvelope(ex);
            }
        }

        private static byte[] OpenTextData(CloudVaultSealedText envelope, byte[] keyData, CloudVaultAadContext? aadContext)
        {
            if (envelope.Algorithm != AesGcmAlgorithm)
            {
                throw CloudVaultCryptoException.InvalidEnvelope();
            }
            var nonce = DecodeBase64(envelope.Nonce);
            var ciphertext = DecodeBase64(envelope.Ciphertext);
            var tag = DecodeBase64(envelope.Tag);
            var schemaVersion = envelope.SchemaVersion ?? 1;
            if (schemaVersion >= CurrentSealedTextSchemaVersion)
            {
                if (aadContext == null)
                {
                    throw CloudVaultCryptoException.InvalidEnvelope();
                }
                var aead = AadData(envelope.Aad, aadContext);
                return AesGcmBox.OpenDetached(nonce, ciphertext, tag, keyData, aead);
            }
            return AesGcmBox.OpenDetached(nonce, ciphertext, tag, keyData, Empty);
        }

        // ── sealBlob / openBlob (AES-256-GCM combined + keyed integrity) ────
        public static CloudVaultBlobEnvelope SealBlob(
            byte[] data, byte[] keyData, int keyVersion = CurrentKeyVersion, CloudVaultAadContext? aadContext = null) =>
            SealBlob(data, keyData, keyVersion, aadContext, nonce: null);

        internal static CloudVaultBlobEnvelope SealBlob(
            byte[] data, byte[] keyData, int keyVersion, CloudVaultAadContext? aadContext, byte[]? nonce)
        {
            var aead = aadContext?.Data ?? Empty;
            var combined = AesGcmBox.SealCombined(data, keyData, aead, nonce);
            return new CloudVaultBlobEnvelope(
                SchemaVersion: CurrentBlobEnvelopeSchemaVersion,
                Algorithm: AesGcmAlgorithm,
                KeyVersion: keyVersion,
                PlaintextSha256: null,
                PlaintextHmac: BlobPlaintextHmac(data, keyData),
                IntegrityHashVersion: BlobIntegrityHashVersion,
                SealedBoxBase64: Convert.ToBase64String(combined),
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
                    plaintext = AesGcmBox.OpenCombined(combined, keyData, Empty);
                    if (envelope.PlaintextSha256 == null || Sha256Hex(plaintext) != envelope.PlaintextSha256)
                    {
                        throw CloudVaultCryptoException.InvalidEnvelope();
                    }
                    break;
                case CurrentBlobEnvelopeSchemaVersion:
                    if (envelope.Aad == BlobEnvelopeAadContext)
                    {
                        plaintext = AesGcmBox.OpenCombined(combined, keyData, Empty);
                    }
                    else
                    {
                        if (aadContext == null)
                        {
                            throw CloudVaultCryptoException.InvalidEnvelope();
                        }
                        plaintext = AesGcmBox.OpenCombined(combined, keyData, AadData(envelope.Aad, aadContext));
                    }
                    if (envelope.IntegrityHashVersion != BlobIntegrityHashVersion
                        || envelope.PlaintextHmac == null
                        || !ConstantTimeEquals(BlobPlaintextHmac(plaintext, keyData), envelope.PlaintextHmac))
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
            var combined = AesGcmBox.SealCombined(data, keyData, aead, nonce);
            return new CloudVaultSealedPayload(
                SchemaVersion: CurrentSealedPayloadSchemaVersion,
                Algorithm: AesGcmAlgorithm,
                KeyVersion: keyVersion,
                VaultKeyId: vaultKeyId,
                SealedBoxBase64: Convert.ToBase64String(combined),
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
                    return AesGcmBox.OpenCombined(combined, keyData, Empty);
                case CurrentSealedPayloadSchemaVersion:
                    if (envelope.Aad == SealedPayloadAadContext)
                    {
                        return AesGcmBox.OpenCombined(
                            combined, keyData, SealedPayloadAad(envelope.Algorithm, envelope.KeyVersion, envelope.VaultKeyId, null));
                    }
                    if (aadContext == null)
                    {
                        throw CloudVaultCryptoException.InvalidEnvelope();
                    }
                    return AesGcmBox.OpenCombined(combined, keyData, AadData(envelope.Aad, aadContext));
                default:
                    throw CloudVaultCryptoException.InvalidEnvelope();
            }
        }

        public static CloudVaultSealedPayload SealRoamingProfile(
            byte[] payloadJson, byte[] keyData, string uid, int keyVersion = CurrentKeyVersion) =>
            SealPayload(payloadJson, keyData, VaultKeyId(keyData), keyVersion, RoamingProfileAadContext(uid));

        public static byte[] OpenRoamingProfile(CloudVaultSealedPayload envelope, byte[] keyData, string uid) =>
            OpenPayload(envelope, keyData, RoamingProfileAadContext(uid));

        private static byte[] SealedPayloadAad(string algorithm, int keyVersion, string vaultKeyId, CloudVaultAadContext? aadContext)
        {
            if (aadContext != null)
            {
                return aadContext.Data;
            }
            return Encoding.UTF8.GetBytes(
                $"{SealedPayloadAadContext}|{algorithm}|keyVersion={keyVersion}|vaultKeyID={vaultKeyId}");
        }

        // ── escrow key-wrap (P-256 ECDH + HKDF + AES-256-GCM) ───────────────
        public static byte[] WrapVaultKey(byte[] keyData, byte[] recipientPublicKeyX963)
        {
            var (scalar, _) = P256KeyAgreement.GenerateEphemeral();
            return WrapVaultKey(keyData, recipientPublicKeyX963, scalar, nonce: null);
        }

        internal static byte[] WrapVaultKey(byte[] keyData, byte[] recipientPublicKeyX963, byte[] ephemeralScalar, byte[]? nonce)
        {
            RequireVaultKey(keyData);
            P256KeyAgreement.ValidateX963(recipientPublicKeyX963);
            var ephemeralPublic = P256KeyAgreement.PublicX963FromScalar(ephemeralScalar);
            var shared = P256KeyAgreement.SharedSecretX(ephemeralScalar, recipientPublicKeyX963);
            var wrappingKey = HkdfDerive(shared, Empty, Encoding.UTF8.GetBytes(EscrowHkdfInfo));
            var combined = AesGcmBox.SealCombined(keyData, wrappingKey, Empty, nonce);
            var wrapped = new byte[ephemeralPublic.Length + combined.Length];
            Buffer.BlockCopy(ephemeralPublic, 0, wrapped, 0, ephemeralPublic.Length);
            Buffer.BlockCopy(combined, 0, wrapped, ephemeralPublic.Length, combined.Length);
            return wrapped;
        }

        public static byte[] UnwrapVaultKey(byte[] ciphertext, byte[] recipientPrivateKeyRaw)
        {
            if (ciphertext.Length <= P256KeyAgreement.X963PublicKeyLength)
            {
                throw CloudVaultCryptoException.InvalidEnvelope();
            }
            var publicKey = new byte[P256KeyAgreement.X963PublicKeyLength];
            var box = new byte[ciphertext.Length - P256KeyAgreement.X963PublicKeyLength];
            Buffer.BlockCopy(ciphertext, 0, publicKey, 0, publicKey.Length);
            Buffer.BlockCopy(ciphertext, publicKey.Length, box, 0, box.Length);
            P256KeyAgreement.ValidateX963(publicKey);
            var shared = P256KeyAgreement.SharedSecretX(recipientPrivateKeyRaw, publicKey);
            var wrappingKey = HkdfDerive(shared, Empty, Encoding.UTF8.GetBytes(EscrowHkdfInfo));
            var keyData = AesGcmBox.OpenCombined(box, wrappingKey, Empty);
            if (keyData.Length != 32)
            {
                throw CloudVaultCryptoException.InvalidKeyLength();
            }
            return keyData;
        }

        // ── recovery wrap (HKDF(recovery key) + AES-256-GCM) ────────────────
        public static byte[] DeriveRecoveryWrappingKey(string recoveryKey)
        {
            var normalized = NormalizeRecoveryKey(recoveryKey);
            if (normalized.Length < 20)
            {
                throw CloudVaultCryptoException.InvalidKeyLength();
            }
            return HkdfDerive(
                Encoding.UTF8.GetBytes(normalized),
                Encoding.UTF8.GetBytes(RecoverySalt),
                Encoding.UTF8.GetBytes(RecoveryWrapInfo));
        }

        public static (string WrappedVaultKeyBase64, string VerificationHash) WrapVaultKeyWithRecovery(
            byte[] vaultKey, string recoveryKey) =>
            WrapVaultKeyWithRecovery(vaultKey, recoveryKey, nonce: null);

        internal static (string WrappedVaultKeyBase64, string VerificationHash) WrapVaultKeyWithRecovery(
            byte[] vaultKey, string recoveryKey, byte[]? nonce)
        {
            RequireVaultKey(vaultKey);
            var wrappingKey = DeriveRecoveryWrappingKey(recoveryKey);
            var combined = AesGcmBox.SealCombined(vaultKey, wrappingKey, Empty, nonce);
            return (Convert.ToBase64String(combined), Sha256Hex(wrappingKey));
        }

        public static byte[] UnwrapVaultKeyWithRecovery(string wrappedVaultKeyBase64, string recoveryKey)
        {
            var combined = DecodeBase64(wrappedVaultKeyBase64);
            var keyData = AesGcmBox.OpenCombined(combined, DeriveRecoveryWrappingKey(recoveryKey), Empty);
            if (keyData.Length != 32)
            {
                throw CloudVaultCryptoException.InvalidKeyLength();
            }
            return keyData;
        }

        public static string RecoveryVerificationHash(string recoveryKey) =>
            Sha256Hex(DeriveRecoveryWrappingKey(recoveryKey));

        // ── vault-keyed HMAC hashes ─────────────────────────────────────────
        public static string BlobPlaintextHmac(byte[] data, byte[] keyData) =>
            KeyedHmacHex(data, keyData, "blob-integrity");

        public static string SessionBodyHash(byte[] data, byte[] keyData) =>
            KeyedHmacHex(data, keyData, "session-body");

        public static string SessionBodyHash(string text, byte[] keyData) =>
            SessionBodyHash(Encoding.UTF8.GetBytes(text), keyData);

        public static string SessionChunkHash(string chunk, byte[] keyData) =>
            KeyedHmacHex(Encoding.UTF8.GetBytes(chunk), keyData, "session-chunk");

        public static string ProjectMemoryContentHash(byte[] data, byte[] keyData) =>
            KeyedHmacHex(data, keyData, "project-memory-content");

        /// <summary>
        /// Vault-keyed deduplication digest for Pensieve chunk plaintext. The
        /// derived key and wire digest match Swift <c>pensieveDedupHash</c> and
        /// the device-side TypeScript memory hook.
        /// </summary>
        public static string PensieveDedupHash(string plaintext, byte[] keyData) =>
            PensieveKeyedHmacHex(Encoding.UTF8.GetBytes(plaintext), keyData, "content");

        /// <summary>
        /// Vault-keyed HMAC for Pensieve/memory opaque doc ids — parity with Swift
        /// <c>pensieveSlugHmac</c> (HKDF info <c>pensieve-dedup:slug</c>).
        /// </summary>
        public static string PensieveSlugHmac(string slug, byte[] keyData) =>
            PensieveKeyedHmacHex(Encoding.UTF8.GetBytes(slug), keyData, "slug");

        private static string PensieveKeyedHmacHex(byte[] data, byte[] keyData, string label)
        {
            RequireVaultKey(keyData);
            var subKey = HkdfDerive(
                keyData,
                Array.Empty<byte>(),
                Encoding.UTF8.GetBytes($"pensieve-dedup:{label}"));
            return HexString(HMACSHA256.HashData(subKey, data));
        }
        private static string KeyedHmacHex(byte[] data, byte[] keyData, string purpose)
        {
            RequireVaultKey(keyData);
            var subKey = HkdfDerive(
                keyData,
                Encoding.UTF8.GetBytes(HmacSalt),
                Encoding.UTF8.GetBytes($"{HmacInfoPrefix}|{purpose}"));
            return HexString(HMACSHA256.HashData(subKey, data));
        }

        // ── hashing helpers ─────────────────────────────────────────────────
        public static string Sha256Hex(byte[] data) => HexString(SHA256.HashData(data));

        public static string Sha256Hex(string text) => Sha256Hex(Encoding.UTF8.GetBytes(text));

        // ── internals ───────────────────────────────────────────────────────
        private static byte[] AadData(string? envelopeAad, CloudVaultAadContext context) =>
            AadData(envelopeAad, context, CloudVaultV1AadRejection.DefaultEnabled);

        internal static byte[] AadData(string? envelopeAad, CloudVaultAadContext context, bool rejectLegacyV1)
        {
            if (envelopeAad == context.StringValue)
            {
                return context.Data;
            }
            if (envelopeAad == context.LegacyV1StringValue)
            {
                if (rejectLegacyV1)
                {
                    throw CloudVaultCryptoException.InvalidEnvelope();
                }
                return context.LegacyV1Data;
            }
            throw CloudVaultCryptoException.InvalidEnvelope();
        }

        private static byte[] HkdfDerive(byte[] ikm, byte[] salt, byte[] info) =>
            HKDF.DeriveKey(HashAlgorithmName.SHA256, ikm, 32, salt, info);

        private static string NormalizeRecoveryKey(string recoveryKey)
        {
            var builder = new StringBuilder(recoveryKey.Length);
            foreach (var c in recoveryKey.ToUpperInvariant())
            {
                if (char.IsLetter(c) || char.IsDigit(c))
                {
                    builder.Append(c);
                }
            }
            return builder.ToString();
        }

        private static void RequireVaultKey(byte[] keyData)
        {
            if (keyData.Length != 32)
            {
                throw CloudVaultCryptoException.InvalidKeyLength();
            }
        }

        private static byte[] DecodeBase64(string value)
        {
            try
            {
                return Convert.FromBase64String(value);
            }
            catch (FormatException ex)
            {
                throw CloudVaultCryptoException.InvalidEnvelope(ex);
            }
        }

        private static bool ConstantTimeEquals(string a, string b)
        {
            var left = Encoding.UTF8.GetBytes(a);
            var right = Encoding.UTF8.GetBytes(b);
            return left.Length == right.Length && CryptographicOperations.FixedTimeEquals(left, right);
        }

        private static string HexString(byte[] data)
        {
            var chars = new char[data.Length * 2];
            for (var i = 0; i < data.Length; i++)
            {
                var b = data[i];
                chars[i * 2] = HexDigit(b >> 4);
                chars[i * 2 + 1] = HexDigit(b & 0xf);
            }
            return new string(chars);
        }

        private static char HexDigit(int value) => (char)(value < 10 ? '0' + value : 'a' + (value - 10));
    }
}
