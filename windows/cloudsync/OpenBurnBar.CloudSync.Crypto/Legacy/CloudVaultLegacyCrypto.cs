using System;
using System.Security.Cryptography;
using System.Text;

namespace OpenBurnBar.CloudSync.Crypto
{
    internal static class CloudVaultLegacyCrypto
    {
        internal const int NonceLength = AesGcmBox.NonceLength;

        private const string EscrowHkdfInfo = "OpenBurnBar-Escrow-v1";
        private const string HmacSalt = "OpenBurnBar-CloudVault-HMAC-Salt-v1";
        private const string HmacInfoPrefix = "OpenBurnBar-CloudVault-HMAC-v1";
        private const string RecoverySalt = "OpenBurnBar-Recovery-Salt-v1";
        private const string RecoveryWrapInfo = "OpenBurnBar-Recovery-Wrap-v1";
        private static readonly byte[] Empty = Array.Empty<byte>();

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

        internal static byte[] SealedPayloadAad(
            string algorithm,
            int keyVersion,
            string vaultKeyId,
            CloudVaultAadContext? aadContext) =>
            aadContext?.Data ?? Encoding.UTF8.GetBytes(
                $"{CloudVaultCrypto.SealedPayloadAadContext}|{algorithm}|keyVersion={keyVersion}|vaultKeyID={vaultKeyId}");

        internal static string VaultKeyId(byte[] keyData)
        {
            RequireVaultKey(keyData);
            return "v1_" + Sha256Hex(keyData).Substring(0, 32);
        }

        internal static string Sha256Hex(byte[] data) => HexString(SHA256.HashData(data));

        internal static string KeyedHmacHex(byte[] data, byte[] keyData, string purpose)
        {
            RequireVaultKey(keyData);
            var subKey = HkdfDerive(
                keyData,
                Encoding.UTF8.GetBytes(HmacSalt),
                Encoding.UTF8.GetBytes($"{HmacInfoPrefix}|{purpose}"));
            return HexString(HMACSHA256.HashData(subKey, data));
        }

        internal static string PensieveSlugHmac(string slug, byte[] keyData) =>
            PensieveKeyedHmacHex(Encoding.UTF8.GetBytes(slug), keyData, "slug");

        internal static byte[] EscrowSeal(byte[] plaintext, byte[] ephemeralPublic, byte[] shared, byte[] nonce)
        {
            var wrappingKey = HkdfDerive(shared, Empty, Encoding.UTF8.GetBytes(EscrowHkdfInfo));
            try
            {
                var combined = AesGcmBox.SealCombined(plaintext, wrappingKey, Empty, nonce);
                var wrapped = new byte[ephemeralPublic.Length + combined.Length];
                Buffer.BlockCopy(ephemeralPublic, 0, wrapped, 0, ephemeralPublic.Length);
                Buffer.BlockCopy(combined, 0, wrapped, ephemeralPublic.Length, combined.Length);
                return wrapped;
            }
            finally
            {
                CryptographicOperations.ZeroMemory(wrappingKey);
            }
        }

        internal static (byte[] EphemeralPublicKey, byte[] AesGcmCombined) EscrowSplitWire(byte[] wire)
        {
            if (wire.Length <= P256KeyAgreement.X963PublicKeyLength)
            {
                throw CloudVaultCryptoException.InvalidEnvelope();
            }
            var publicKey = new byte[P256KeyAgreement.X963PublicKeyLength];
            var combined = new byte[wire.Length - publicKey.Length];
            Buffer.BlockCopy(wire, 0, publicKey, 0, publicKey.Length);
            Buffer.BlockCopy(wire, publicKey.Length, combined, 0, combined.Length);
            P256KeyAgreement.ValidateX963(publicKey);
            return (publicKey, combined);
        }

        internal static byte[] EscrowOpen(byte[] combined, byte[] shared)
        {
            var wrappingKey = HkdfDerive(shared, Empty, Encoding.UTF8.GetBytes(EscrowHkdfInfo));
            try
            {
                return AesGcmBox.OpenCombined(combined, wrappingKey, Empty);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(wrappingKey);
            }
        }

        internal static byte[] DeriveRecoveryWrappingKey(string recoveryKey)
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

        internal static (byte[] Combined, string VerificationHash) RecoveryWrapVaultKey(
            byte[] vaultKey,
            string recoveryKey,
            byte[] nonce)
        {
            var wrappingKey = DeriveRecoveryWrappingKey(recoveryKey);
            try
            {
                return (AesGcmBox.SealCombined(vaultKey, wrappingKey, Empty, nonce), Sha256Hex(wrappingKey));
            }
            finally
            {
                CryptographicOperations.ZeroMemory(wrappingKey);
            }
        }

        internal static byte[] RecoveryOpenVaultKey(byte[] combined, string recoveryKey)
        {
            var wrappingKey = DeriveRecoveryWrappingKey(recoveryKey);
            try
            {
                return AesGcmBox.OpenCombined(combined, wrappingKey, Empty);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(wrappingKey);
            }
        }

        internal static string RecoveryVerificationHash(string recoveryKey)
        {
            var wrappingKey = DeriveRecoveryWrappingKey(recoveryKey);
            try
            {
                return Sha256Hex(wrappingKey);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(wrappingKey);
            }
        }

        internal static (byte[] Nonce, byte[] Ciphertext, byte[] Tag, byte[] Combined) SealDetached(
            byte[] plaintext,
            byte[] keyData,
            byte[] aad,
            byte[] nonce) => AesGcmBox.SealDetached(plaintext, keyData, aad, nonce);

        internal static byte[] SealCombined(byte[] plaintext, byte[] keyData, byte[] aad, byte[] nonce) =>
            AesGcmBox.SealCombined(plaintext, keyData, aad, nonce);

        internal static byte[] OpenCombined(byte[] combined, byte[] keyData, byte[] aad) =>
            AesGcmBox.OpenCombined(combined, keyData, aad);

        internal static string OpenTextDetached(
            byte[] nonce,
            byte[] ciphertext,
            byte[] tag,
            byte[] keyData,
            byte[] aad) => DecodeUtf8Strict(AesGcmBox.OpenDetached(nonce, ciphertext, tag, keyData, aad));

        internal static string EncodeBase64(byte[] data) => Convert.ToBase64String(data);

        internal static byte[] DecodeBase64(string value)
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

        internal static void RequireVaultKey(byte[] keyData)
        {
            if (keyData.Length != 32)
            {
                throw CloudVaultCryptoException.InvalidKeyLength();
            }
        }

        internal static bool ConstantTimeEquals(string a, string b)
        {
            var left = Encoding.UTF8.GetBytes(a);
            var right = Encoding.UTF8.GetBytes(b);
            return left.Length == right.Length && CryptographicOperations.FixedTimeEquals(left, right);
        }

        internal static string PensieveKeyedHmacHex(byte[] data, byte[] keyData, string label)
        {
            RequireVaultKey(keyData);
            var subKey = HkdfDerive(keyData, Empty, Encoding.UTF8.GetBytes($"pensieve-dedup:{label}"));
            return HexString(HMACSHA256.HashData(subKey, data));
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

        private static string DecodeUtf8Strict(byte[] data)
        {
            try
            {
                return new UTF8Encoding(false, true).GetString(data);
            }
            catch (DecoderFallbackException ex)
            {
                throw CloudVaultCryptoException.InvalidEnvelope(ex);
            }
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
