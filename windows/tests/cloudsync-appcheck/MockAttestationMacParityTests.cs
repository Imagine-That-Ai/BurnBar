using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using OpenBurnBar.CloudSync.AppCheck.Attestation;
using Xunit;

namespace OpenBurnBar.CloudSync.AppCheck.Tests;

/// <summary>
/// BYTE-PARITY of the C# mock attestation MAC against committed golden vectors.
/// The vectors were produced by an INDEPENDENT oracle (openssl sha256) using the
/// exact formula the Node server's <c>signMockAttestation</c> computes, so a green
/// run proves the C# client would sign a claim the server accepts, and a drift in
/// the domain string, field order, separator, secret, or hex casing fails here.
/// </summary>
public sealed class MockAttestationMacParityTests
{
    private sealed record Vector(string Name, string AppId, string Nonce, long IssuedAtMs, string Mac);

    private sealed record VectorFile(string Domain, string Secret, IReadOnlyList<Vector> Vectors);

    private static VectorFile LoadVectors()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "mock-attestation-vectors.json");
        Assert.True(File.Exists(path), $"Golden vector fixture missing at {path}");

        using var doc = JsonDocument.Parse(File.ReadAllText(path));
        var root = doc.RootElement;
        var domain = root.GetProperty("domain").GetString()!;
        var secret = root.GetProperty("secret").GetString()!;
        var list = new List<Vector>();
        foreach (var v in root.GetProperty("vectors").EnumerateArray())
        {
            list.Add(new Vector(
                v.GetProperty("name").GetString()!,
                v.GetProperty("appId").GetString()!,
                v.GetProperty("nonce").GetString()!,
                v.GetProperty("issuedAtMs").GetInt64(),
                v.GetProperty("mac").GetString()!));
        }
        return new VectorFile(domain, secret, list);
    }

    public static IEnumerable<object[]> Vectors()
    {
        foreach (var v in LoadVectors().Vectors)
        {
            yield return new object[] { v.Name, v.AppId, v.Nonce, v.IssuedAtMs, v.Mac };
        }
    }

    [Theory]
    [MemberData(nameof(Vectors))]
    public void Sign_matches_golden_vector_byte_for_byte(
        string name, string appId, string nonce, long issuedAtMs, string expectedMac)
    {
        _ = name;
        var actual = MockAttestationMac.Sign(appId, nonce, issuedAtMs);
        Assert.Equal(expectedMac, actual);
    }

    [Fact]
    public void Constants_match_the_server_domain_and_secret()
    {
        var file = LoadVectors();
        // The fixture's recorded domain/secret ARE the server's constants; assert the
        // C# constants equal them so a rename on either side is caught.
        Assert.Equal(MockAttestationMac.Domain, file.Domain);
        Assert.Equal(MockAttestationMac.SharedSecret, file.Secret);
        Assert.Equal("openburnbar.appcheck.windows.mock.v1", MockAttestationMac.Domain);
        Assert.Equal("openburnbar-windows-appcheck-mock-fixture-secret", MockAttestationMac.SharedSecret);
    }

    [Fact]
    public void Mac_is_lowercase_hex_64_chars()
    {
        var mac = MockAttestationMac.Sign(TestConstants.PlaceholderAppId, "abcdef0123456789abcd", 1_700_000_000_000);
        Assert.Equal(64, mac.Length);
        Assert.Matches("^[0-9a-f]{64}$", mac);
    }

    [Fact]
    public void Different_secret_yields_a_different_mac()
    {
        // The server would reject a claim signed with the wrong secret as `forged`.
        var good = MockAttestationMac.Sign(TestConstants.PlaceholderAppId, "abcdef0123456789abcd", 42);
        var bad = MockAttestationMac.Sign(TestConstants.PlaceholderAppId, "abcdef0123456789abcd", 42, "not-the-secret");
        Assert.NotEqual(good, bad);
    }

    [Fact]
    public void Each_field_is_domain_separated_no_ambiguous_concatenation()
    {
        // Moving a character across the '|' boundary must change the MAC, proving the
        // separator is load-bearing (no field-splice forgery).
        var a = MockAttestationMac.Sign("app", "1234567890abcdef", 42);
        var b = MockAttestationMac.Sign("ap", "p1234567890abcdef", 42);
        Assert.NotEqual(a, b);
    }
}
