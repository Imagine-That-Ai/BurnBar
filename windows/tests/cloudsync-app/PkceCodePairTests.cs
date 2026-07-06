using System;
using System.Linq;
using OpenBurnBar.App.CloudSync;
using Xunit;

namespace OpenBurnBar.App.CloudSync.Tests;

/// <summary>PKCE (RFC 7636) verifier/challenge/state generation.</summary>
public sealed class PkceCodePairTests
{
    [Fact]
    public void Challenge_is_the_s256_of_the_verifier()
    {
        PkceCodePair pair = PkceCodePair.Generate();
        Assert.Equal(PkceCodePair.ChallengeFor(pair.CodeVerifier), pair.CodeChallenge);
        Assert.Equal("S256", PkceCodePair.ChallengeMethod);
    }

    [Fact]
    public void Verifier_challenge_and_state_are_url_safe_and_unpadded()
    {
        PkceCodePair pair = PkceCodePair.Generate();
        foreach (string token in new[] { pair.CodeVerifier, pair.CodeChallenge, pair.State })
        {
            Assert.NotEmpty(token);
            Assert.DoesNotContain('+', token);
            Assert.DoesNotContain('/', token);
            Assert.DoesNotContain('=', token);
            Assert.All(token, c => Assert.True(char.IsLetterOrDigit(c) || c is '-' or '_'));
        }
    }

    [Fact]
    public void Each_generation_is_unique()
    {
        string[] verifiers = Enumerable.Range(0, 16).Select(_ => PkceCodePair.Generate().CodeVerifier).ToArray();
        Assert.Equal(verifiers.Length, verifiers.Distinct().Count());
    }

    [Fact]
    public void Challenge_is_a_known_vector()
    {
        // RFC 7636 Appendix B worked example.
        const string verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
        Assert.Equal("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", PkceCodePair.ChallengeFor(verifier));
    }
}
