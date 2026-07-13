using System;
using System.Text;
using DomainCore = uniffi.openburnbar_domain_ffi.OpenburnbarDomainFfiMethods;
using Xunit;

namespace OpenBurnBar.App.Quota.Tests;

public sealed class DomainCoreCloudVaultAesTests
{
    [Fact]
    public void NativeAesGcmMatchesCanonicalEmptyPlaintextVector()
    {
        byte[] key = new byte[32];
        byte[] nonce = new byte[12];
        byte[] combined = DomainCore.CloudVaultAesGcmSealCombined([], key, nonce, []);

        Assert.Equal(
            "000000000000000000000000530f8afbc74536b9a963b4f1c4cb738b",
            Convert.ToHexStringLower(combined));
        Assert.Empty(DomainCore.CloudVaultAesGcmOpenCombined(combined, key, []));
    }

    [Fact]
    public void NativeAesGcmRoundTripsStrictUtf8Text()
    {
        byte[] plaintext = Encoding.UTF8.GetBytes("OpenBurnBar");
        byte[] aad = Encoding.UTF8.GetBytes("aad");
        byte[] key = new byte[32];
        var sealedBox = DomainCore.CloudVaultAesGcmSealDetached(
            plaintext,
            key,
            new byte[12],
            aad);

        Assert.Equal(
            "OpenBurnBar",
            DomainCore.CloudVaultAesGcmOpenTextDetached(
                sealedBox.nonce,
                sealedBox.ciphertext,
                sealedBox.tag,
                key,
                aad));
    }
}
