using System;
using System.IO;
using System.Text.Json;
using Xunit;
using DomainCore = uniffi.openburnbar_domain_ffi.OpenburnbarDomainFfiMethods;

namespace OpenBurnBar.CloudSync.Crypto.Tests
{
    [CollectionDefinition(Name, DisableParallelization = true)]
    public sealed class DomainCoreCloudVaultCollection
    {
        public const string Name = "domain-core-cloudvault-environment";
    }

    [Collection(DomainCoreCloudVaultCollection.Name)]
    public sealed class DomainCoreCloudVaultBridgeTests
    {
        [Fact]
        public void NativeLibrary_ReportsBuildIdentity()
        {
            if (!NativeRequired()) return;
            using var manifest = JsonDocument.Parse(File.ReadAllText(
                Path.Combine(AppContext.BaseDirectory, "Fixtures", "domain-core-union-abi-manifest.json")));
            Assert.Equal(manifest.RootElement.GetProperty("abiVersion").GetUInt32(), DomainCore.DomainCoreAbiVersion());
            Assert.Equal(manifest.RootElement.GetProperty("coreVersion").GetString(), DomainCore.DomainCoreVersion());
            var sourceFingerprint = DomainCore.DomainCoreSourceFingerprint();
            Assert.Matches("^[0-9a-f]{64}$", sourceFingerprint);
            var expectedSourceFingerprint = manifest.RootElement.GetProperty("sourceSha256").GetString();
            Assert.Matches("^[0-9a-f]{64}$", expectedSourceFingerprint!);
            Assert.Equal(expectedSourceFingerprint, sourceFingerprint);
        }

        [Fact]
        public void RustMode_ConsumesCanonicalDeterministicKat()
        {
            if (!NativeRequired()) return;
            using var mode = new EnvironmentVariableScope("OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE", "rust");
            using var document = JsonDocument.Parse(File.ReadAllText(
                Path.Combine(AppContext.BaseDirectory, "Fixtures", "cloudvault-deterministic-kat.json")));
            var root = document.RootElement;

            foreach (var vector in root.GetProperty("aad").EnumerateArray())
            {
                var context = new CloudVaultAadContext(
                    vector.GetProperty("uid").GetString()!,
                    vector.GetProperty("collection").GetString()!,
                    vector.GetProperty("docID").GetString()!,
                    vector.GetProperty("field").GetString()!,
                    vector.GetProperty("schemaVersion").GetInt32(),
                    vector.GetProperty("purpose").GetString()!);
                Assert.Equal(vector.GetProperty("v1").GetString(), context.LegacyV1StringValue);
                Assert.Equal(vector.GetProperty("v2").GetString(), context.StringValue);
            }

            foreach (var vector in root.GetProperty("sha256").EnumerateArray())
            {
                Assert.Equal(
                    vector.GetProperty("hex").GetString(),
                    CloudVaultCrypto.Sha256Hex(Convert.FromHexString(vector.GetProperty("dataHex").GetString()!)));
            }

            foreach (var vector in root.GetProperty("vaultKeyID").EnumerateArray())
            {
                Assert.Equal(
                    vector.GetProperty("value").GetString(),
                    CloudVaultCrypto.VaultKeyId(Convert.FromHexString(vector.GetProperty("keyHex").GetString()!)));
            }

            foreach (var vector in root.GetProperty("keyedHashes").EnumerateArray())
            {
                var data = Convert.FromHexString(vector.GetProperty("dataHex").GetString()!);
                var key = Convert.FromHexString(vector.GetProperty("keyHex").GetString()!);
                var actual = vector.GetProperty("purpose").GetString() switch
                {
                    "blob-integrity" => CloudVaultCrypto.BlobPlaintextHmac(data, key),
                    "session-body" => CloudVaultCrypto.SessionBodyHash(data, key),
                    "session-chunk" => CloudVaultCrypto.SessionChunkHash(
                        System.Text.Encoding.UTF8.GetString(data), key),
                    "project-memory-content" => CloudVaultCrypto.ProjectMemoryContentHash(data, key),
                    _ => throw new InvalidOperationException("Unknown deterministic hash purpose."),
                };
                Assert.Equal(vector.GetProperty("hex").GetString(), actual);
            }

            foreach (var vector in root.GetProperty("aesGcm").EnumerateArray())
            {
                var key = Convert.FromHexString(vector.GetProperty("keyHex").GetString()!);
                var nonce = Convert.FromHexString(vector.GetProperty("nonceHex").GetString()!);
                var plaintext = Convert.FromHexString(vector.GetProperty("plaintextHex").GetString()!);
                var aad = Convert.FromHexString(vector.GetProperty("aadHex").GetString()!);
                var combined = DomainCoreCloudVaultBridge.SealCombined(
                    plaintext,
                    key,
                    nonce,
                    aad,
                    () => throw new InvalidOperationException("legacy AES must remain lazy"));
                Assert.Equal(vector.GetProperty("combinedBase64").GetString(), Convert.ToBase64String(combined));
                Assert.Equal(
                    plaintext,
                    DomainCoreCloudVaultBridge.OpenCombined(
                        combined,
                        key,
                        aad,
                        () => throw new InvalidOperationException("legacy AES must remain lazy")));
            }
        }

        [Fact]
        public void RustMode_DoesNotEvaluateLegacyDelegate()
        {
            if (!NativeRequired()) return;
            using var mode = new EnvironmentVariableScope("OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE", "rust");

            var result = DomainCoreCloudVaultBridge.Sha256Hex(
                Array.Empty<byte>(),
                () => throw new InvalidOperationException("legacy must remain lazy"));

            Assert.Equal("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", result);
        }

        [Fact]
        public void RustMode_ConsumesOpaqueIdentifierKatWithoutLegacyFallback()
        {
            if (!NativeRequired()) return;
            using var mode = new EnvironmentVariableScope("OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE", "rust");
            using var document = JsonDocument.Parse(File.ReadAllText(
                Path.Combine(AppContext.BaseDirectory, "Fixtures", "opaque-identifiers-kat.json")));
            var root = document.RootElement;
            var key = Convert.FromHexString(root.GetProperty("vaultKeyHex").GetString()!);

            var pensieve = root.GetProperty("pensieve");
            Assert.Equal(
                pensieve.GetProperty("dedupHash").GetString(),
                CloudVaultCrypto.PensieveDedupHash(pensieve.GetProperty("plaintext").GetString()!, key));

            Assert.Equal(
                pensieve.GetProperty("slugHmac").GetString(),
                CloudVaultCrypto.PensieveSlugHmac(pensieve.GetProperty("slug").GetString()!, key));
        }

        [Fact]
        public void ShadowMode_ReturnsLegacyResult()
        {
            if (!NativeRequired()) return;
            using var mode = new EnvironmentVariableScope("OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE", "shadow");

            var result = DomainCoreCloudVaultBridge.Sha256Hex(Array.Empty<byte>(), () => "legacy-result");

            Assert.Equal("legacy-result", result);
        }

        [Fact]
        public void RustMode_NativeLoadFailureNeverFallsBackWhenNativeRequirementFlagIsUnset()
        {
            if (!NativeRequired()) return;
            using var mode = new EnvironmentVariableScope("OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE", "rust");
            using var nativeRequirement = new EnvironmentVariableScope("OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE", null);
            var legacyInvoked = false;

            var error = Assert.Throws<InvalidOperationException>(() =>
                DomainCoreCloudVaultBridge.Apply(
                    "forced_native_load_failure",
                    () => throw new DllNotFoundException("forced native load failure"),
                    () =>
                    {
                        legacyInvoked = true;
                        return "legacy-result";
                    },
                    StringComparer.Ordinal.Equals));

            Assert.Contains("Rust mode requires ABI v3", error.Message, StringComparison.Ordinal);
            Assert.False(legacyInvoked);
        }

        [Fact]
        public void ShadowMode_NativeLoadFailureKeepsLegacyAuthoritative()
        {
            if (!NativeRequired()) return;
            using var mode = new EnvironmentVariableScope("OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE", "shadow");
            using var nativeRequirement = new EnvironmentVariableScope("OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE", null);
            var legacyInvoked = false;

            var result = DomainCoreCloudVaultBridge.Apply(
                "forced_native_load_failure",
                () => throw new DllNotFoundException("forced native load failure"),
                () =>
                {
                    legacyInvoked = true;
                    return "legacy-result";
                },
                StringComparer.Ordinal.Equals);

            Assert.Equal("legacy-result", result);
            Assert.True(legacyInvoked);
        }

        [Fact]
        public void ShadowMode_UnexpectedRustFailureReturnsExactLegacyResultOnce()
        {
            if (!NativeRequired()) return;
            using var mode = new EnvironmentVariableScope("OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE", "shadow");
            var legacyInvocations = 0;
            var expected = new byte[] { 0x00, 0x7f, 0xff };

            var result = DomainCoreCloudVaultBridge.Apply(
                "forced_rust_failure",
                () => throw new InvalidOperationException("sensitive Rust failure"),
                () =>
                {
                    legacyInvocations++;
                    return expected;
                },
                (left, right) => left.AsSpan().SequenceEqual(right));

            Assert.Same(expected, result);
            Assert.Equal(1, legacyInvocations);
        }

        [Fact]
        public void ShadowEvidence_OperationLoadFailureRetainsReadableLoadedIdentity()
        {
            if (!NativeRequired()) return;
            using var mode = new EnvironmentVariableScope("OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE", "shadow");
            DomainCoreCloudVaultShadowComparison? comparison = null;
            DomainCoreCloudVaultShadowEvidence.Configure(value => comparison = value);
            try
            {
                var result = DomainCoreCloudVaultBridge.Apply(
                    "cloudvault_sha256",
                    () => throw new DllNotFoundException("forced native load failure"),
                    () => "legacy-result",
                    StringComparer.Ordinal.Equals);

                Assert.Equal("legacy-result", result);
                Assert.NotNull(comparison);
                Assert.Equal("native_error", comparison.MismatchCategory);
                Assert.False(string.IsNullOrWhiteSpace(comparison.LoadedCoreVersion));
                Assert.Equal(3u, comparison.LoadedCoreAbiVersion);
                Assert.Matches("^[0-9a-f]{64}$", comparison.LoadedCoreSourceSha256);
            }
            finally
            {
                DomainCoreCloudVaultShadowEvidence.Configure(null);
            }
        }

        [Fact]
        public void ShadowEvidence_MatchingCallCarriesCompleteLoadedIdentity()
        {
            if (!NativeRequired()) return;
            using var mode = new EnvironmentVariableScope("OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE", "shadow");
            DomainCoreCloudVaultShadowComparison? comparison = null;
            DomainCoreCloudVaultShadowEvidence.Configure(value => comparison = value);
            try
            {
                _ = DomainCoreCloudVaultBridge.Sha256Hex(Array.Empty<byte>(), () =>
                    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");

                Assert.NotNull(comparison);
                Assert.Equal("match", comparison.Outcome);
                Assert.False(string.IsNullOrWhiteSpace(comparison.LoadedCoreVersion));
                Assert.Equal(3u, comparison.LoadedCoreAbiVersion);
                Assert.Matches("^[0-9a-f]{64}$", comparison.LoadedCoreSourceSha256!);
            }
            finally
            {
                DomainCoreCloudVaultShadowEvidence.Configure(null);
            }
        }

        [Fact]
        public void ShadowEvidence_PensieveOpaqueIdentifiersUseCanonicalRoute()
        {
            if (!NativeRequired()) return;
            using var mode = new EnvironmentVariableScope("OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE", "shadow");
            var comparisons = new DomainCoreCloudVaultShadowComparison?[2];
            var index = 0;
            DomainCoreCloudVaultShadowEvidence.Configure(value => comparisons[index++] = value);
            try
            {
                var key = new byte[32];
                const string plaintext = "pensieve opaque identifier";
                const string slug = "pensieve-opaque-identifier";

                _ = DomainCoreCloudVaultBridge.PensieveDedupHash(
                    plaintext,
                    key,
                    () => DomainCore.CloudVaultPensieveDedupHash(plaintext, key));
                _ = DomainCoreCloudVaultBridge.PensieveSlugHmac(
                    slug,
                    key,
                    () => DomainCore.CloudVaultPensieveSlugHmac(slug, key));

                Assert.Collection(
                    comparisons,
                    comparison =>
                    {
                        Assert.NotNull(comparison);
                        Assert.Equal("cloudvault", comparison.Domain);
                        Assert.Equal("opaque-identifiers", comparison.Slice);
                        Assert.Equal("windows", comparison.Consumer);
                        Assert.Equal("pensieve_dedup_hash", comparison.Operation);
                    },
                    comparison =>
                    {
                        Assert.NotNull(comparison);
                        Assert.Equal("cloudvault", comparison.Domain);
                        Assert.Equal("opaque-identifiers", comparison.Slice);
                        Assert.Equal("windows", comparison.Consumer);
                        Assert.Equal("pensieve_slug_hmac", comparison.Operation);
                    });
            }
            finally
            {
                DomainCoreCloudVaultShadowEvidence.Configure(null);
            }
        }

        [Fact]
        public void RustMode_MapsInvalidVaultKeyToFailClosedError()
        {
            if (!NativeRequired()) return;
            using var mode = new EnvironmentVariableScope("OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE", "rust");

            var error = Assert.Throws<CloudVaultCryptoException>(() => CloudVaultCrypto.VaultKeyId(new byte[31]));

            Assert.Equal(CloudVaultCryptoErrorCode.InvalidKeyLength, error.Code);
        }

        [Fact]
        public void RustMode_ResolvesV2AndHonorsLegacyRejection()
        {
            if (!NativeRequired()) return;
            using var mode = new EnvironmentVariableScope("OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE", "rust");
            var context = new CloudVaultAadContext("user_alice", "cloudSessions", "doc_123", "title", 2, "title");

            Assert.Equal(context.Data, CloudVaultCrypto.AadData(context.StringValue, context, rejectLegacyV1: true));
            Assert.Equal(
                context.LegacyV1Data,
                CloudVaultCrypto.AadData(context.LegacyV1StringValue, context, rejectLegacyV1: false));
            Assert.Equal(
                CloudVaultCryptoErrorCode.InvalidEnvelope,
                Assert.Throws<CloudVaultCryptoException>(() =>
                    CloudVaultCrypto.AadData(context.LegacyV1StringValue, context, rejectLegacyV1: true)).Code);
        }

        [Fact]
        public void RustMode_RejectsNonCanonicalBase64AcceptedByLegacyDecoder()
        {
            if (!NativeRequired()) return;
            using var mode = new EnvironmentVariableScope("OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE", "rust");

            var envelope = CloudVaultCrypto.SealText("secret", new byte[32]);
            var paddedWithWhitespace = envelope with { Nonce = envelope.Nonce + "\n" };

            Assert.Equal(
                CloudVaultCryptoErrorCode.InvalidEnvelope,
                Assert.Throws<CloudVaultCryptoException>(() =>
                    CloudVaultCrypto.OpenText(paddedWithWhitespace, new byte[32])).Code);
        }

        [Fact]
        public void RustMode_AuthenticationFailureNeverInvokesLegacyFallback()
        {
            if (!NativeRequired()) return;
            using var mode = new EnvironmentVariableScope("OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE", "rust");
            var sealedBox = DomainCoreCloudVaultBridge.SealCombined(
                Array.Empty<byte>(),
                new byte[32],
                new byte[12],
                Array.Empty<byte>(),
                () => throw new InvalidOperationException("legacy seal must remain lazy"));
            sealedBox[^1] ^= 1;

            Assert.Equal(
                CloudVaultCryptoErrorCode.InvalidEnvelope,
                Assert.Throws<CloudVaultCryptoException>(() =>
                    DomainCoreCloudVaultBridge.OpenCombined(
                        sealedBox,
                        new byte[32],
                        Array.Empty<byte>(),
                        () => throw new InvalidOperationException("legacy open must remain lazy"))).Code);
        }

        [Fact]
        public void RustMode_ConsumesRecoveryAndEscrowCanonicalKat()
        {
            if (!NativeRequired()) return;
            using var mode = new EnvironmentVariableScope("OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE", "rust");
            using var document = JsonDocument.Parse(File.ReadAllText(
                Path.Combine(AppContext.BaseDirectory, "Fixtures", "cloudvault-deterministic-kat.json")));

            var recovery = document.RootElement.GetProperty("recovery");
            var recoveryKey = recovery.GetProperty("formattedKey").GetString()!;
            var vaultKey = Convert.FromHexString(recovery.GetProperty("vaultKeyHex").GetString()!);
            var recoveryNonce = Convert.FromHexString(recovery.GetProperty("nonceHex").GetString()!);
            var recoveryWrapped = CloudVaultCrypto.WrapVaultKeyWithRecovery(vaultKey, recoveryKey, recoveryNonce);
            Assert.Equal(recovery.GetProperty("combinedHex").GetString(), Convert.ToHexStringLower(
                Convert.FromBase64String(recoveryWrapped.WrappedVaultKeyBase64)));
            Assert.Equal(recovery.GetProperty("verificationHash").GetString(), recoveryWrapped.VerificationHash);
            Assert.Equal(vaultKey, CloudVaultCrypto.UnwrapVaultKeyWithRecovery(
                recoveryWrapped.WrappedVaultKeyBase64,
                recoveryKey));

            var escrow = document.RootElement.GetProperty("p256Escrow");
            var ephemeralPublic = Convert.FromHexString(escrow.GetProperty("ephemeralPublicKeyHex").GetString()!);
            var shared = Convert.FromHexString(escrow.GetProperty("sharedSecretHex").GetString()!);
            var nonce = Convert.FromHexString(escrow.GetProperty("nonceHex").GetString()!);
            var wire = DomainCoreCloudVaultBridge.EscrowSeal(
                vaultKey,
                ephemeralPublic,
                shared,
                nonce,
                () => throw new InvalidOperationException("legacy escrow seal must remain lazy"));
            Assert.Equal(escrow.GetProperty("wireHex").GetString(), Convert.ToHexStringLower(wire));
            Assert.Equal(
                vaultKey,
                DomainCoreCloudVaultBridge.EscrowOpen(
                    wire,
                    shared,
                    () => throw new InvalidOperationException("legacy escrow open must remain lazy")));
        }

        [Fact]
        public void ShadowMode_ExecutesRecoveryAndEscrowWithLegacyAuthoritative()
        {
            if (!NativeRequired()) return;
            using var mode = new EnvironmentVariableScope("OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE", "shadow");
            var vaultKey = new byte[32];
            const string recoveryKey = "abc-defg-hjkm-npq-rst-vwxyz-23456789";

            var recoveryWrapped = CloudVaultCrypto.WrapVaultKeyWithRecovery(vaultKey, recoveryKey, new byte[12]);
            Assert.Equal(vaultKey, CloudVaultCrypto.UnwrapVaultKeyWithRecovery(
                recoveryWrapped.WrappedVaultKeyBase64,
                recoveryKey));

            byte[] recipientPrivate = new byte[32];
            recipientPrivate[^1] = 1;
            byte[] recipientPublic = P256KeyAgreement.PublicX963FromScalar(recipientPrivate);
            byte[] ephemeralPrivate = new byte[32];
            ephemeralPrivate[^1] = 2;
            byte[] wire = CloudVaultCrypto.WrapVaultKey(vaultKey, recipientPublic, ephemeralPrivate, new byte[12]);
            Assert.Equal(vaultKey, CloudVaultCrypto.UnwrapVaultKey(wire, recipientPrivate));
        }

        [Fact]
        public void RustMode_MapsRecoveryAndPublicKeyFailures()
        {
            if (!NativeRequired()) return;
            using var mode = new EnvironmentVariableScope("OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE", "rust");

            Assert.Equal(
                CloudVaultCryptoErrorCode.InvalidKeyLength,
                Assert.Throws<CloudVaultCryptoException>(() =>
                    CloudVaultCrypto.DeriveRecoveryWrappingKey("too-short")).Code);
            Assert.Equal(
                CloudVaultCryptoErrorCode.InvalidPublicKey,
                Assert.Throws<CloudVaultCryptoException>(() =>
                    CloudVaultCrypto.WrapVaultKey(new byte[32], new byte[65], new byte[32], new byte[12])).Code);
        }

        private static bool NativeRequired() =>
            string.Equals(
                Environment.GetEnvironmentVariable("OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE"),
                "1",
                StringComparison.Ordinal);

        private sealed class EnvironmentVariableScope : IDisposable
        {
            private readonly string name;
            private readonly string? previous;

            internal EnvironmentVariableScope(string name, string? value)
            {
                this.name = name;
                previous = Environment.GetEnvironmentVariable(name);
                Environment.SetEnvironmentVariable(name, value);
            }

            public void Dispose() => Environment.SetEnvironmentVariable(name, previous);
        }
    }
}
