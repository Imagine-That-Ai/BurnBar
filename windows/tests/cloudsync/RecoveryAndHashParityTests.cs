using Xunit;

namespace OpenBurnBar.CloudSync.Crypto.Tests
{
    /// <summary>
    /// Byte-parity for the symmetric recovery-key wrap, the vault-keyed HMAC hashes
    /// (blob-integrity / session-body / session-chunk / project-memory-content), and
    /// the plain SHA-256 helper, against the committed CryptoKit vectors.
    /// </summary>
    public sealed class RecoveryAndHashParityTests
    {
        [Fact]
        public void RecoveryUnwrap_CommittedBytes_MatchesVaultKey()
        {
            foreach (var vector in KatVectors.Section("recoveryWrap").EnumerateArray())
            {
                var recoveryKey = vector.Str("recoveryKey");
                var wrapped = vector.Str("wrappedVaultKeyBase64");
                var expected = vector.Str("vaultKeyHex");

                var unwrapped = CloudVaultCrypto.UnwrapVaultKeyWithRecovery(wrapped, recoveryKey);

                Assert.Equal(expected, KatVectors.ToHex(unwrapped));
            }
        }

        [Fact]
        public void RecoveryWrap_WithPinnedNonce_ReproducesCommittedBytes()
        {
            foreach (var vector in KatVectors.Section("recoveryWrap").EnumerateArray())
            {
                var recoveryKey = vector.Str("recoveryKey");
                var vaultKey = vector.Hex("vaultKeyHex");
                var nonce = vector.Hex("nonceHex");

                var (wrappedBase64, verificationHash) =
                    CloudVaultCrypto.WrapVaultKeyWithRecovery(vaultKey, recoveryKey, nonce);

                Assert.Equal(vector.Str("wrappedVaultKeyBase64"), wrappedBase64);
                Assert.Equal(vector.Str("verificationHash"), verificationHash);
                Assert.Equal(vector.Str("verificationHash"), CloudVaultCrypto.RecoveryVerificationHash(recoveryKey));
            }
        }

        [Fact]
        public void KeyedHashes_MatchCommittedHex()
        {
            foreach (var vector in KatVectors.Section("keyedHashes").EnumerateArray())
            {
                var key = vector.Hex("keyHex");
                var data = vector.Hex("dataHex");
                var expected = vector.Str("hex");
                var purpose = vector.Str("purpose");

                var actual = purpose switch
                {
                    "blob-integrity" => CloudVaultCrypto.BlobPlaintextHmac(data, key),
                    "session-body" => CloudVaultCrypto.SessionBodyHash(data, key),
                    "session-chunk" => CloudVaultCrypto.SessionChunkHash(
                        System.Text.Encoding.UTF8.GetString(data), key),
                    "project-memory-content" => CloudVaultCrypto.ProjectMemoryContentHash(data, key),
                    _ => null,
                };

                Assert.NotNull(actual);
                Assert.Equal(expected, actual);
            }
        }

        [Fact]
        public void Sha256_MatchesCommittedHex()
        {
            foreach (var vector in KatVectors.Section("sha256").EnumerateArray())
            {
                Assert.Equal(vector.Str("hex"), CloudVaultCrypto.Sha256Hex(vector.Str("dataUtf8")));
            }
        }

        [Fact]
        public void MemoryCitationHmac_MatchesCommittedHex()
        {
            foreach (var vector in KatVectors.Section("memoryCitationHmac").EnumerateArray())
            {
                var key = vector.Hex("keyHex");
                var actual = CloudVaultCrypto.MemoryCitationHmac(
                    vector.Str("threadLogicalId"),
                    vector.Str("messageId"),
                    vector.Int("occurrence"),
                    vector.Str("contentHash"),
                    key);
                Assert.Equal(vector.Str("hex"), actual);
            }
        }
    }
}
