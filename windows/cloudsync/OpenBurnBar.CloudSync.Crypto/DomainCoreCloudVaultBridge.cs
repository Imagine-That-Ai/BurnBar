using System;
using System.Diagnostics;
using System.Security.Cryptography;
using DomainCore = uniffi.openburnbar_domain_ffi.OpenburnbarDomainFfiMethods;
using DomainAadContext = uniffi.openburnbar_domain_ffi.CloudVaultAadContextInput;
using DomainCloudVaultException = uniffi.openburnbar_domain_ffi.CloudVaultFfiException;
using DomainHashPurpose = uniffi.openburnbar_domain_ffi.CloudVaultHashPurpose;

namespace OpenBurnBar.CloudSync.Crypto
{
    internal enum DomainCoreCloudVaultMigrationMode
    {
        Legacy,
        Shadow,
        Rust,
    }

    internal static class DomainCoreCloudVaultBridge
    {
        private const string ModeVariable = "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE";
        private const string RequireNativeVariable = "OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE";

        internal static string AadV2(
            string uid,
            string collection,
            string docId,
            string field,
            int schemaVersion,
            string purpose,
            Func<string> legacy) =>
            Apply(
                "cloudvault_aad_v2",
                () => DomainCore.CloudVaultAadV2(
                    uid,
                    collection,
                    docId,
                    field,
                    ToSchemaVersion(schemaVersion),
                    purpose),
                legacy,
                StringComparer.Ordinal.Equals);

        internal static string AadV1(
            string uid,
            string collection,
            string docId,
            string field,
            Func<string> legacy) =>
            Apply(
                "cloudvault_aad_v1",
                () => DomainCore.CloudVaultAadV1(uid, collection, docId, field),
                legacy,
                StringComparer.Ordinal.Equals);

        internal static byte[] ResolveAad(
            string envelopeAad,
            CloudVaultAadContext context,
            bool rejectLegacy,
            Func<byte[]> legacy) =>
            Apply(
                "cloudvault_resolve_aad",
                () => DomainCore.CloudVaultResolveAad(
                    envelopeAad,
                    new DomainAadContext(
                        context.Uid,
                        context.Collection,
                        context.DocId,
                        context.Field,
                        ToSchemaVersion(context.SchemaVersion),
                        context.Purpose),
                    rejectLegacy),
                legacy,
                (left, right) => CryptographicOperations.FixedTimeEquals(left, right));

        internal static string Sha256Hex(byte[] data, Func<string> legacy) =>
            Apply(
                "cloudvault_sha256",
                () => DomainCore.CloudVaultSha256Hex(data),
                legacy,
                StringComparer.Ordinal.Equals);

        internal static string VaultKeyId(byte[] key, Func<string> legacy) =>
            Apply(
                "cloudvault_key_id",
                () => DomainCore.CloudVaultKeyId(key),
                legacy,
                StringComparer.Ordinal.Equals);

        internal static string KeyedHashHex(
            byte[] data,
            byte[] key,
            DomainHashPurpose purpose,
            Func<string> legacy) =>
            Apply(
                "cloudvault_keyed_hash",
                () => DomainCore.CloudVaultKeyedHashHex(data, key, purpose),
                legacy,
                StringComparer.Ordinal.Equals);

        internal static (byte[] Nonce, byte[] Ciphertext, byte[] Tag, byte[] Combined) SealDetached(
            byte[] plaintext,
            byte[] key,
            byte[] nonce,
            byte[] aad,
            Func<(byte[] Nonce, byte[] Ciphertext, byte[] Tag, byte[] Combined)> legacy) =>
            Apply(
                "cloudvault_aes_seal_detached",
                () =>
                {
                    var sealedBox = DomainCore.CloudVaultAesGcmSealDetached(plaintext, key, nonce, aad);
                    return (
                        Nonce: sealedBox.nonce,
                        Ciphertext: sealedBox.ciphertext,
                        Tag: sealedBox.tag,
                        Combined: Combine(sealedBox.nonce, sealedBox.ciphertext, sealedBox.tag));
                },
                legacy,
                (left, right) =>
                    FixedTimeEquals(left.Nonce, right.Nonce)
                    && FixedTimeEquals(left.Ciphertext, right.Ciphertext)
                    && FixedTimeEquals(left.Tag, right.Tag)
                    && FixedTimeEquals(left.Combined, right.Combined));

        internal static byte[] SealCombined(
            byte[] plaintext,
            byte[] key,
            byte[] nonce,
            byte[] aad,
            Func<byte[]> legacy) =>
            Apply(
                "cloudvault_aes_seal_combined",
                () => DomainCore.CloudVaultAesGcmSealCombined(plaintext, key, nonce, aad),
                legacy,
                FixedTimeEquals);

        internal static byte[] OpenDetached(
            byte[] nonce,
            byte[] ciphertext,
            byte[] tag,
            byte[] key,
            byte[] aad,
            Func<byte[]> legacy) =>
            Apply(
                "cloudvault_aes_open_detached",
                () => DomainCore.CloudVaultAesGcmOpenDetached(nonce, ciphertext, tag, key, aad),
                legacy,
                FixedTimeEquals);

        internal static string OpenTextDetached(
            byte[] nonce,
            byte[] ciphertext,
            byte[] tag,
            byte[] key,
            byte[] aad,
            Func<string> legacy) =>
            Apply(
                "cloudvault_aes_open_text",
                () => DomainCore.CloudVaultAesGcmOpenTextDetached(nonce, ciphertext, tag, key, aad),
                legacy,
                StringComparer.Ordinal.Equals);

        internal static byte[] OpenCombined(
            byte[] combined,
            byte[] key,
            byte[] aad,
            Func<byte[]> legacy) =>
            Apply(
                "cloudvault_aes_open_combined",
                () => DomainCore.CloudVaultAesGcmOpenCombined(combined, key, aad),
                legacy,
                FixedTimeEquals);

        internal static string Base64Encode(byte[] data, Func<string> legacy) =>
            Apply(
                "cloudvault_base64_encode",
                () => DomainCore.CloudVaultBase64Encode(data),
                legacy,
                StringComparer.Ordinal.Equals);

        internal static byte[] Base64Decode(string value, Func<byte[]> legacy) =>
            Apply(
                "cloudvault_base64_decode",
                () => DomainCore.CloudVaultBase64DecodeStrict(value),
                legacy,
                FixedTimeEquals);

        internal static DomainCoreCloudVaultMigrationMode ResolveMode(string? raw) =>
            raw?.Trim().ToLowerInvariant() switch
            {
                "shadow" => DomainCoreCloudVaultMigrationMode.Shadow,
                "rust" => DomainCoreCloudVaultMigrationMode.Rust,
                _ => DomainCoreCloudVaultMigrationMode.Legacy,
            };

        private static T Apply<T>(
            string operation,
            Func<T> rust,
            Func<T> legacy,
            Func<T, T, bool> equivalent)
        {
            var mode = ResolveMode(Environment.GetEnvironmentVariable(ModeVariable));
            if (mode == DomainCoreCloudVaultMigrationMode.Legacy)
            {
                return legacy();
            }

            if (!TryInvoke(rust, out var rustOutcome))
            {
                if (NativeRequired())
                {
                    throw new InvalidOperationException(
                        $"Domain-core native library is required for {operation}, but it could not be loaded.");
                }

                Trace.TraceWarning("domain_core.{0}.native_unavailable mode={1}", operation, mode);
                return legacy();
            }

            if (mode == DomainCoreCloudVaultMigrationMode.Rust)
            {
                return rustOutcome!.GetOrThrow();
            }

            var legacyOutcome = Capture(legacy);
            if (!Equivalent(rustOutcome!, legacyOutcome, equivalent))
            {
                Trace.TraceWarning(
                    "domain_core.{0}.shadow_mismatch core={1} mismatch_count=1 legacy_category={2} rust_category={3}",
                    operation,
                    DomainCore.DomainCoreVersion(),
                    legacyOutcome.Category,
                    rustOutcome!.Category);
            }

            return legacyOutcome.GetOrThrow();
        }

        private static bool TryInvoke<T>(Func<T> operation, out Outcome<T>? outcome)
        {
            outcome = null;
            try
            {
                if (DomainCore.DomainCoreAbiVersion() != 2)
                {
                    return false;
                }

                outcome = Capture(operation);
                return true;
            }
            catch (Exception error) when (IsNativeLoadFailure(error))
            {
                return false;
            }
        }

        private static Outcome<T> Capture<T>(Func<T> operation)
        {
            try
            {
                return Outcome<T>.Success(operation());
            }
            catch (DomainCloudVaultException error)
            {
                return Outcome<T>.Failure(Map(error));
            }
            catch (CloudVaultCryptoException error)
            {
                return Outcome<T>.Failure(error);
            }
        }

        private static bool Equivalent<T>(Outcome<T> left, Outcome<T> right, Func<T, T, bool> equivalent)
        {
            if (left.Error != null || right.Error != null)
            {
                return left.Error?.Code == right.Error?.Code;
            }

            return equivalent(left.Value!, right.Value!);
        }

        private static CloudVaultCryptoException Map(DomainCloudVaultException error) => error switch
        {
            DomainCloudVaultException.InvalidKeyLength => CloudVaultCryptoException.InvalidKeyLength(),
            _ => CloudVaultCryptoException.InvalidEnvelope(error),
        };

        private static uint ToSchemaVersion(int schemaVersion)
        {
            if (schemaVersion < 0)
            {
                throw CloudVaultCryptoException.InvalidEnvelope();
            }

            return (uint)schemaVersion;
        }

        private static bool NativeRequired() =>
            string.Equals(Environment.GetEnvironmentVariable(RequireNativeVariable), "1", StringComparison.Ordinal);

        private static bool IsNativeLoadFailure(Exception error) =>
            error is DllNotFoundException
                or EntryPointNotFoundException
                or BadImageFormatException
                || error is TypeInitializationException initialization
                    && initialization.InnerException is Exception inner
                    && IsNativeLoadFailure(inner);

        private static bool FixedTimeEquals(byte[] left, byte[] right) =>
            left.Length == right.Length && CryptographicOperations.FixedTimeEquals(left, right);

        private static byte[] Combine(params byte[][] parts)
        {
            var length = 0;
            foreach (var part in parts)
            {
                length = checked(length + part.Length);
            }

            var combined = new byte[length];
            var offset = 0;
            foreach (var part in parts)
            {
                Buffer.BlockCopy(part, 0, combined, offset, part.Length);
                offset += part.Length;
            }
            return combined;
        }

        private sealed class Outcome<T>
        {
            private Outcome(T? value, CloudVaultCryptoException? error)
            {
                Value = value;
                Error = error;
            }

            internal T? Value { get; }
            internal CloudVaultCryptoException? Error { get; }
            internal string Category => Error == null ? "success" : Error.Code.ToString();

            internal static Outcome<T> Success(T value) => new(value, null);
            internal static Outcome<T> Failure(CloudVaultCryptoException error) => new(default, error);

            internal T GetOrThrow()
            {
                if (Error != null)
                {
                    throw Error;
                }

                return Value!;
            }
        }
    }
}
