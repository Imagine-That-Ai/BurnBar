using System;
using System.IO;
using System.Text.Json;
using Xunit;

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
        public void ShadowMode_ReturnsLegacyResult()
        {
            if (!NativeRequired()) return;
            using var mode = new EnvironmentVariableScope("OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE", "shadow");

            var result = DomainCoreCloudVaultBridge.Sha256Hex(Array.Empty<byte>(), () => "legacy-result");

            Assert.Equal("legacy-result", result);
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

        private static bool NativeRequired() =>
            string.Equals(
                Environment.GetEnvironmentVariable("OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE"),
                "1",
                StringComparison.Ordinal);

        private sealed class EnvironmentVariableScope : IDisposable
        {
            private readonly string name;
            private readonly string? previous;

            internal EnvironmentVariableScope(string name, string value)
            {
                this.name = name;
                previous = Environment.GetEnvironmentVariable(name);
                Environment.SetEnvironmentVariable(name, value);
            }

            public void Dispose() => Environment.SetEnvironmentVariable(name, previous);
        }
    }
}
