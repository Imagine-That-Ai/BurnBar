using System;
using DomainCore = uniffi.openburnbar_domain_ffi.OpenburnbarDomainFfiMethods;
using Xunit;

namespace OpenBurnBar.App.Quota.Tests;

public sealed class DomainCoreCloudVaultRecoveryEscrowTests
{
    private const string PublicKeyHex =
        "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296" +
        "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5";

    [Fact]
    public void NativeRecoveryMatchesCanonicalVector()
    {
        const string recoveryKey = "abc-defg-hjkm-npq-rst-vwxyz-23456789";
        byte[] vaultKey = Sequence(0, 32);
        var wrapped = DomainCore.CloudVaultRecoveryWrapVaultKey(vaultKey, recoveryKey, Sequence(0, 12));

        Assert.Equal(
            "3d3722923f9209d63093b1212a55b5fb5de462c00137ba6d6b46228404873166",
            wrapped.verificationHash);
        Assert.Equal(vaultKey, DomainCore.CloudVaultRecoveryOpenVaultKey(wrapped.combined, recoveryKey));
    }

    [Fact]
    public void NativeP256EscrowValidatesPointAndOpensEmptyPayload()
    {
        byte[] publicKey = Convert.FromHexString(PublicKeyHex);
        byte[] sharedSecret = Sequence(0xa0, 32);
        DomainCore.CloudVaultValidateP256X963PublicKey(publicKey);

        byte[] wire = DomainCore.CloudVaultEscrowSeal([], publicKey, sharedSecret, Sequence(0, 12));

        Assert.Empty(DomainCore.CloudVaultEscrowOpen(wire, sharedSecret));
    }

    private static byte[] Sequence(int start, int count)
    {
        var bytes = new byte[count];
        for (int index = 0; index < bytes.Length; index++)
        {
            bytes[index] = checked((byte)(start + index));
        }
        return bytes;
    }
}
