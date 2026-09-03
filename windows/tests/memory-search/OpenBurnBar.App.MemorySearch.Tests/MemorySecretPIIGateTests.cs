using System;
using System.Linq;
using OpenBurnBar.App.MemorySearch.Memory;
using Xunit;

namespace OpenBurnBar.App.MemorySearch.Tests;

/// <summary>
/// The corpus-driven secret/PII gate. Swift: <c>MemorySecretPIIGate</c>. Covers the committed-corpus
/// load, explicit secret/PII patterns, the Luhn + IPv4 validators, entropy heuristics, redaction,
/// derived-view decoding, and the fail-closed invariant (injected unavailable corpus).
/// </summary>
public sealed class MemorySecretPIIGateTests
{
    private static readonly MemorySecretPIIGate Gate = MemorySecretPIIGate.Shared;

    [Fact]
    public void EmbeddedCorpus_LoadsAndReportsVersion()
    {
        Assert.True(Gate.IsAvailable);
        Assert.Equal("openburnbar-project-code-secret-corpus-v5", Gate.CorpusVersion);
    }

    [Fact]
    public void BenignText_IsAllowed()
    {
        Assert.Equal(MemoryGateVerdict.Kind.Allow, Gate.Evaluate("The user prefers dark mode and two-space indents.").Decision);
    }

    [Theory]
    // Synthetic secret VECTORS that exercise the PII gate's detectors — not real
    // credentials (openai/anthropic keys are fake sequences, AKIA…EXAMPLE is the
    // AWS docs sample, the JWT is a hand-forged token). gitleaks:allow on each.
    [InlineData("my key is sk-abcdefghijklmnopqrstuvwxyz012345", "openai-api-key")] // gitleaks:allow
    [InlineData("token sk-ant-abcdefghijklmnop0123", "anthropic-api-key")] // gitleaks:allow
    [InlineData("ghp_abcdefghijklmnopqrstuvwxyz0123456789", "github-token")] // gitleaks:allow
    [InlineData("AKIAIOSFODNN7EXAMPLE here", "aws-access-key")] // gitleaks:allow
    [InlineData("jwt eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N", "jwt")] // gitleaks:allow
    public void KnownSecrets_AreRejectedWithExpectedFindingId(string text, string expectedId)
    {
        var verdict = Gate.Evaluate(text);
        Assert.Equal(MemoryGateVerdict.Kind.Reject, verdict.Decision);
        Assert.Contains(expectedId, verdict.Findings.Select(f => f.Id));
    }

    [Fact]
    public void PrivateKeyBlock_IsRejected()
    {
        const string text = "-----BEGIN RSA PRIVATE KEY-----\nMIIB...\n-----END RSA PRIVATE KEY-----";
        Assert.Equal(MemoryGateVerdict.Kind.Reject, Gate.Evaluate(text).Decision);
    }

    [Fact]
    public void Email_And_Ssn_AreRejectedAsPii()
    {
        Assert.Contains("email-address", Gate.FindingIds("reach me at alice@example.com"));
        Assert.Contains("us-ssn", Gate.FindingIds("ssn 123-45-6789"));
    }

    [Fact]
    public void CreditCard_LuhnValidatorGatesTheMatch()
    {
        // 4111 1111 1111 1111 is a valid Luhn test card → rejected.
        Assert.Contains("credit-card-number", Gate.FindingIds("card 4111111111111111"));
        // A 16-digit run that fails Luhn is NOT a finding (data-integrity guard).
        Assert.DoesNotContain("credit-card-number", Gate.FindingIds("order 1234567812345678"));
    }

    [Fact]
    public void Ipv4_OctetValidatorGatesTheMatch()
    {
        Assert.Contains("ipv4-address", Gate.FindingIds("server at 192.168.1.100"));
        // Out-of-range octets (a version string) must NOT be flagged.
        Assert.DoesNotContain("ipv4-address", Gate.FindingIds("version 999.888.777.666"));
    }

    [Fact]
    public void HighEntropyToken_IsRejected()
    {
        // A mixed-charset 40-char token that matches no explicit pattern → general entropy path.
        var ids = Gate.FindingIds("secret value aB3xK9mZ2qW7rT1yU5pL8nD4vC6bH0jF2gS3dA1e");
        Assert.Contains("high-entropy-token", ids);
    }

    [Fact]
    public void HighEntropyHexToken_IsRejected()
    {
        // A 40-char hex string caps below the general 4.2 threshold but trips the hex path (>= 3.0).
        var ids = Gate.FindingIds("digest a94a8fe5ccb19ba61c4c0873d391e987982fbbd3");
        Assert.Contains("high-entropy-hex-token", ids);
    }

    [Fact]
    public void Redact_RemovesLocatablePii_AndReGatesClean()
    {
        var verdict = Gate.Evaluate("email me at alice@example.com please", MemoryGatePolicy.Redact);
        Assert.Equal(MemoryGateVerdict.Kind.Redact, verdict.Decision);
        Assert.NotNull(verdict.RedactedText);
        Assert.DoesNotContain("alice@example.com", verdict.RedactedText!);
        Assert.Contains("[REDACTED-PII]", verdict.RedactedText!);
    }

    [Fact]
    public void Base64EncodedSecret_IsCaughtViaDerivedView()
    {
        // base64("sk-abcdefghijklmnopqrstuvwxyz012345") — the raw string hides the key; the decoded
        // view surfaces it (non-locatable), so the gate still rejects.
        string encoded = Convert.ToBase64String(
            System.Text.Encoding.ASCII.GetBytes("sk-abcdefghijklmnopqrstuvwxyz012345"));
        var verdict = Gate.Evaluate("blob " + encoded);
        Assert.Equal(MemoryGateVerdict.Kind.Reject, verdict.Decision);
        Assert.Contains("openai-api-key", verdict.Findings.Select(f => f.Id));
    }

    [Fact]
    public void Labels_And_FindingIds_AreDedupedAndOrderPreserving()
    {
        const string text = "keys sk-abcdefghijklmnopqrstuvwxyz012345 and sk-zzzzzzzzzzzzzzzzzzzzzzzz9999";
        Assert.Equal(new[] { "openai-api-key" }, Gate.FindingIds(text));
        Assert.Equal(new[] { "OpenAI API key detected" }, Gate.Labels(text));
    }

    [Fact]
    public void UnavailableCorpus_FailsClosed_RejectingEverything()
    {
        var gate = new MemorySecretPIIGate(MemoryGateCorpus.Unavailable);
        Assert.False(gate.IsAvailable);

        var verdict = gate.Evaluate("totally benign text");
        Assert.Equal(MemoryGateVerdict.Kind.Reject, verdict.Decision);
        Assert.Equal(MemorySecretPIIGate.CorpusUnavailableFindingId, Assert.Single(verdict.Findings).Id);

        Assert.Equal(new[] { MemorySecretPIIGate.CorpusUnavailableFindingId }, gate.FindingIds("x"));
        Assert.Equal(new[] { MemorySecretPIIGate.CorpusUnavailableLabel }, gate.Labels("x"));
    }

    [Fact]
    public void CorruptCorpusJson_LoadsAsUnavailable()
    {
        Assert.False(MemoryGateCorpus.FromJson("{ not valid").Available);
        // Missing required pattern field → whole corpus unavailable (fail-closed).
        Assert.False(MemoryGateCorpus.FromJson("{\"version\":\"v\",\"patterns\":[{\"id\":\"x\"}]}").Available);
    }

    [Fact]
    public void CustomCorpus_IsInjectableAndDrivesTheGate()
    {
        const string json = "{\"version\":\"custom-v1\",\"patterns\":[" +
            "{\"id\":\"forbidden-word\",\"label\":\"Forbidden word\",\"kind\":\"secret\",\"regex\":\"FORBIDDEN\"}]}";
        var gate = new MemorySecretPIIGate(MemoryGateCorpus.FromJson(json));

        Assert.True(gate.IsAvailable);
        Assert.Equal("custom-v1", gate.CorpusVersion);
        Assert.Equal(MemoryGateVerdict.Kind.Reject, gate.Evaluate("this is FORBIDDEN").Decision);
        Assert.Equal(MemoryGateVerdict.Kind.Allow, gate.Evaluate("this is fine").Decision);
    }

    [Fact]
    public void Validators_AreCorrect()
    {
        Assert.True(MemoryGateValidators.PassesLuhn("4111111111111111"));
        Assert.False(MemoryGateValidators.PassesLuhn("1234567812345678"));
        Assert.False(MemoryGateValidators.PassesLuhn("411111")); // too short
        Assert.True(MemoryGateValidators.HasBoundedIpv4Octets("0.0.0.0"));
        Assert.True(MemoryGateValidators.HasBoundedIpv4Octets("255.255.255.255"));
        Assert.False(MemoryGateValidators.HasBoundedIpv4Octets("256.1.1.1"));
        Assert.False(MemoryGateValidators.HasBoundedIpv4Octets("1.2.3"));
    }

    [Fact]
    public void ShannonEntropy_IsZeroForEmpty_AndPositiveForMixed()
    {
        Assert.Equal(0, MemorySecretPIIGate.ShannonEntropy(""));
        Assert.True(MemorySecretPIIGate.ShannonEntropy("abcdefghij") > 3.0);
    }
}
