using System;
using System.Diagnostics;
using System.Security.Cryptography;
using DomainCore = uniffi.openburnbar_domain_ffi.OpenburnbarDomainFfiMethods;
using OpenBurnBar.App.Configuration;
using DomainAadContext = uniffi.openburnbar_domain_ffi.CloudVaultAadContextInput;
using DomainCloudVaultException = uniffi.openburnbar_domain_ffi.CloudVaultFfiException;
using DomainHashPurpose = uniffi.openburnbar_domain_ffi.CloudVaultHashPurpose;
using DomainEscrowWireParts = uniffi.openburnbar_domain_ffi.CloudVaultEscrowWireParts;

namespace OpenBurnBar.CloudSync.Crypto
{
    internal enum DomainCoreCloudVaultMigrationMode
    {
        Legacy,
        Shadow,
        Rust,
    }

    public sealed record DomainCoreCloudVaultShadowComparison(
        string Domain,
        string Slice,
        string Consumer,
        string Operation,
        string? LoadedCoreVersion,
        uint? LoadedCoreAbiVersion,
        string? LoadedCoreSourceSha256,
        string Outcome,
        string? MismatchCategory,
        long LegacyMicros,
        long RustMicros);

    public static class DomainCoreCloudVaultShadowEvidence
    {
        public static void Configure(Action<DomainCoreCloudVaultShadowComparison>? sink) =>
            DomainCoreCloudVaultBridge.ComparisonSink = sink;
    }

    internal static class DomainCoreCloudVaultBridge
    {
        private const string ModeVariable = "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE";

        internal static Action<DomainCoreCloudVaultShadowComparison>? ComparisonSink { get; set; }

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

        internal static byte[] RecoveryWrappingKey(string recoveryKey, Func<byte[]> legacy) =>
            Apply(
                "cloudvault_recovery_wrapping_key",
                () => DomainCore.CloudVaultRecoveryWrappingKey(recoveryKey),
                legacy,
                FixedTimeEquals);

        internal static string RecoveryVerificationHash(string recoveryKey, Func<string> legacy) =>
            Apply(
                "cloudvault_recovery_verification_hash",
                () => DomainCore.CloudVaultRecoveryVerificationHash(recoveryKey),
                legacy,
                StringComparer.Ordinal.Equals);

        internal static (byte[] Combined, string VerificationHash) RecoveryWrapVaultKey(
            byte[] vaultKey,
            string recoveryKey,
            byte[] nonce,
            Func<(byte[] Combined, string VerificationHash)> legacy) =>
            Apply(
                "cloudvault_recovery_wrap_vault_key",
                () =>
                {
                    var wrapped = DomainCore.CloudVaultRecoveryWrapVaultKey(vaultKey, recoveryKey, nonce);
                    return (Combined: wrapped.combined, VerificationHash: wrapped.verificationHash);
                },
                legacy,
                (left, right) =>
                    FixedTimeEquals(left.Combined, right.Combined)
                    && StringComparer.Ordinal.Equals(left.VerificationHash, right.VerificationHash));

        internal static byte[] RecoveryOpenVaultKey(
            byte[] combined,
            string recoveryKey,
            Func<byte[]> legacy) =>
            Apply(
                "cloudvault_recovery_open_vault_key",
                () => DomainCore.CloudVaultRecoveryOpenVaultKey(combined, recoveryKey),
                legacy,
                FixedTimeEquals);

        internal static void ValidateP256PublicKey(byte[] publicKey, Action legacy)
        {
            _ = Apply(
                "cloudvault_validate_p256_public_key",
                () =>
                {
                    DomainCore.CloudVaultValidateP256X963PublicKey(publicKey);
                    return true;
                },
                () =>
                {
                    legacy();
                    return true;
                },
                (left, right) => left == right);
        }

        internal static byte[] EscrowSeal(
            byte[] plaintext,
            byte[] ephemeralPublicKey,
            byte[] sharedSecret,
            byte[] nonce,
            Func<byte[]> legacy) =>
            Apply(
                "cloudvault_escrow_seal",
                () => DomainCore.CloudVaultEscrowSeal(plaintext, ephemeralPublicKey, sharedSecret, nonce),
                legacy,
                FixedTimeEquals);

        internal static byte[] EscrowOpen(
            byte[] wire,
            byte[] sharedSecret,
            Func<byte[]> legacy) =>
            Apply(
                "cloudvault_escrow_open",
                () => DomainCore.CloudVaultEscrowOpen(wire, sharedSecret),
                legacy,
                FixedTimeEquals);

        internal static (byte[] EphemeralPublicKey, byte[] AesGcmCombined) EscrowSplitWire(
            byte[] wire,
            Func<(byte[] EphemeralPublicKey, byte[] AesGcmCombined)> legacy) =>
            Apply(
                "cloudvault_escrow_split_wire",
                () => FromDomain(DomainCore.CloudVaultEscrowSplitWire(wire)),
                legacy,
                (left, right) =>
                    FixedTimeEquals(left.EphemeralPublicKey, right.EphemeralPublicKey)
                    && FixedTimeEquals(left.AesGcmCombined, right.AesGcmCombined));

        internal static DomainCoreCloudVaultMigrationMode ResolveMode(string? raw) =>
            raw?.Trim().ToLowerInvariant() switch
            {
                "shadow" => DomainCoreCloudVaultMigrationMode.Shadow,
                "rust" => DomainCoreCloudVaultMigrationMode.Rust,
                _ => DomainCoreCloudVaultMigrationMode.Legacy,
            };

        internal static T Apply<T>(
            string operation,
            Func<T> rust,
            Func<T> legacy,
            Func<T, T, bool> equivalent)
        {
            var mode = ResolveMode(DomainCoreBuildProfileResolver.Mode("cloudVault", ModeVariable));
            if (mode == DomainCoreCloudVaultMigrationMode.Legacy)
            {
                return legacy();
            }

            if (mode == DomainCoreCloudVaultMigrationMode.Rust)
            {
                if (!TryInvoke(rust, out var rustOutcome))
                {
                    Trace.TraceWarning("domain_core.{0}.native_unavailable mode={1}", operation, mode);
                    throw new InvalidOperationException(
                        $"Domain-core Rust mode requires ABI v3 for {operation}, but it could not be loaded.");
                }

                return rustOutcome!.GetOrThrow();
            }

            long legacyStarted = Stopwatch.GetTimestamp();
            var legacyOutcome = Capture(legacy);
            long legacyMicros = ElapsedMicros(legacyStarted);
            long rustStarted = Stopwatch.GetTimestamp();
            LoadedCoreIdentity? loadedIdentity = null;
            if (!TryLoadShadowIdentity(out loadedIdentity))
            {
                Trace.TraceWarning("domain_core.{0}.native_unavailable mode={1}", operation, mode);
                RecordComparison(operation, null, false, "native_unavailable", legacyMicros, ElapsedMicros(rustStarted));
            }
            else
            {
                DomainCoreCandidateIdentity? expectedIdentity = CurrentSignedCandidateIdentity();
                if (expectedIdentity is not null && !Matches(expectedIdentity, loadedIdentity))
                {
                    Trace.TraceWarning("domain_core.{0}.loaded_identity_mismatch mode={1}", operation, mode);
                    RecordComparison(
                        operation,
                        loadedIdentity,
                        false,
                        "loaded_identity_mismatch",
                        legacyMicros,
                        ElapsedMicros(rustStarted));
                }
                else if (expectedIdentity is null && loadedIdentity.CoreAbiVersion != 3)
                {
                    Trace.TraceWarning("domain_core.{0}.native_unavailable mode={1}", operation, mode);
                    RecordComparison(
                        operation,
                        null,
                        false,
                        "native_unavailable",
                        legacyMicros,
                        ElapsedMicros(rustStarted));
                }
                else
                {
                    try
                    {
                        var rustOutcome = Capture(rust);
                        bool matches = Equivalent(rustOutcome!, legacyOutcome, equivalent);
                        if (!matches)
                        {
                            Trace.TraceWarning(
                                "domain_core.{0}.shadow_mismatch core={1} mismatch_count=1 legacy_category={2} rust_category={3}",
                                operation,
                                loadedIdentity.CoreVersion,
                                legacyOutcome.Category,
                                rustOutcome!.Category);
                        }
                        RecordComparison(
                            operation,
                            loadedIdentity,
                            matches,
                            matches ? null : "result_mismatch",
                            legacyMicros,
                            ElapsedMicros(rustStarted));
                    }
                    catch (Exception error) when (IsNativeLoadFailure(error))
                    {
                        string category = loadedIdentity is null ? "native_unavailable" : "native_error";
                        Trace.TraceWarning("domain_core.{0}.{1} mode={2}", operation, category, mode);
                        RecordComparison(
                            operation,
                            loadedIdentity,
                            false,
                            category,
                            legacyMicros,
                            ElapsedMicros(rustStarted));
                    }
                    catch (Exception)
                    {
                        Trace.TraceWarning("domain_core.{0}.rust_error mode={1}", operation, mode);
                        RecordComparison(
                            operation,
                            loadedIdentity,
                            false,
                            "native_error",
                            legacyMicros,
                            ElapsedMicros(rustStarted));
                    }
                }
            }

            return legacyOutcome.GetOrThrow();
        }

        private static long ElapsedMicros(long started) => Math.Clamp(
            (long)(Stopwatch.GetElapsedTime(started).TotalMilliseconds * 1_000),
            0,
            600_000_000);

        private static void RecordComparison(
            string operation,
            LoadedCoreIdentity? loadedIdentity,
            bool equivalent,
            string? mismatchCategory,
            long legacyMicros,
            long rustMicros)
        {
            if (ComparisonSink is null) return;
            string slice = operation.Contains("escrow", StringComparison.Ordinal) ? "escrow"
                : operation.Contains("recovery", StringComparison.Ordinal) ? "recovery"
                : operation.Contains("aes", StringComparison.Ordinal)
                    || operation.Contains("seal", StringComparison.Ordinal)
                    || operation.Contains("open", StringComparison.Ordinal) ? "aes"
                : "foundation";
            ComparisonSink(new DomainCoreCloudVaultShadowComparison(
                "cloudvault",
                slice,
                "windows",
                operation,
                loadedIdentity?.CoreVersion,
                loadedIdentity?.CoreAbiVersion,
                loadedIdentity?.CoreSourceSha256,
                equivalent ? "match" : "mismatch",
                mismatchCategory,
                legacyMicros,
                rustMicros));
        }

        private static DomainCoreCandidateIdentity? CurrentSignedCandidateIdentity()
        {
            var profile = DomainCoreBuildProfileResolver.Current();
            return profile.IsValid
                && profile.ArtifactAuthority == "signed"
                && profile.EvidenceEnabled
                && profile.RolloutChannel is "internal" or "beta"
                ? profile.CandidateIdentity
                : null;
        }

        private static bool TryLoadShadowIdentity(out LoadedCoreIdentity identity)
        {
            identity = null!;
            try
            {
                identity = new(
                    DomainCore.DomainCoreVersion(),
                    DomainCore.DomainCoreAbiVersion(),
                    DomainCore.DomainCoreSourceFingerprint());
                return true;
            }
            catch
            {
                return false;
            }
        }

        private static bool Matches(DomainCoreCandidateIdentity expected, LoadedCoreIdentity loaded) =>
            loaded.CoreVersion == expected.ExpectedCoreVersion
            && loaded.CoreAbiVersion == expected.ExpectedCoreAbiVersion
            && loaded.CoreSourceSha256 == expected.ExpectedCoreSourceSha256;

        private static bool TryInvoke<T>(Func<T> operation, out Outcome<T>? outcome)
        {
            outcome = null;
            try
            {
                if (DomainCore.DomainCoreAbiVersion() != 3)
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
            DomainCloudVaultException.InvalidRecoveryKey => CloudVaultCryptoException.InvalidKeyLength(),
            DomainCloudVaultException.InvalidP256PublicKey => CloudVaultCryptoException.InvalidPublicKey(),
            _ => CloudVaultCryptoException.InvalidEnvelope(error),
        };

        private static (byte[] EphemeralPublicKey, byte[] AesGcmCombined) FromDomain(
            DomainEscrowWireParts parts) =>
            (parts.ephemeralPublicKey, parts.aesGcmCombined);

        private static uint ToSchemaVersion(int schemaVersion)
        {
            if (schemaVersion < 0)
            {
                throw CloudVaultCryptoException.InvalidEnvelope();
            }

            return (uint)schemaVersion;
        }

        private static bool IsNativeLoadFailure(Exception error) =>
            error is DllNotFoundException
                or EntryPointNotFoundException
                or BadImageFormatException
                // UniFFI performs checksum/version validation in the generated
                // static constructor. An older native artifact therefore fails
                // before DomainCoreAbiVersion() can return, wrapped as a
                // TypeInitializationException. Shadow mode may continue with
                // legacy; explicit Rust mode handles this result fail-closed.
                or TypeInitializationException;

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

        private sealed record LoadedCoreIdentity(
            string CoreVersion,
            uint CoreAbiVersion,
            string CoreSourceSha256);
    }
}
