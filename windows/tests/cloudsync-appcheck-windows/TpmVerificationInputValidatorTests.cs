using System;
using OpenBurnBar.CloudSync.AppCheck.Verifier.Windows;
using Xunit;

namespace OpenBurnBar.CloudSync.AppCheck.Windows.Tests;

public sealed class TpmVerificationInputValidatorTests
{
    [Theory]
    [InlineData(null, "AQ==")]
    [InlineData("", "AQ==")]
    [InlineData("AQ==", null)]
    [InlineData("AQ==", "")]
    public void TryValidate_RejectsMissingBinaryFields(string? platformClaim, string? subjectPublicKey)
    {
        var request = new TpmVerificationRequest(
            1,
            "user-1",
            "1:123:web:abc",
            "challenge-0123456789abcdef",
            "nonce-0123456789abcdef",
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            platformClaim!,
            subjectPublicKey!);

        bool valid = TpmVerificationInputValidator.TryValidate(
            request,
            "1:123:web:abc",
            out byte[] publicKey,
            out byte[] claim);

        Assert.False(valid);
        Assert.Empty(publicKey);
        Assert.Empty(claim);
    }
}
