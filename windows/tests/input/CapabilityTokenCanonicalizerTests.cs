// Pins the capability-token canonical signable bytes — the exact bytes an issuer signs and
// a leaf verifies. Byte-parity with macOS CapabilityTokenSigner.SignableBody: sorted keys,
// nil optionals omitted, ISO8601 fractional-second UTC dates, minimal escaping.

using System;
using System.Collections.Generic;
using OpenBurnBar.Pal.Input;
using Xunit;

namespace OpenBurnBar.Pal.Input.Tests;

public sealed class CapabilityTokenCanonicalizerTests
{
    private static VirtualHidCapabilityToken Token(
        string? boundEscrowDeviceId = null,
        string? attestationHashBlake3 = null)
    {
        return new VirtualHidCapabilityToken(
            CapabilityTokenDomain.ComputerUse,
            nonce: "nonce-abc",
            issuedAt: new DateTimeOffset(2026, 7, 3, 0, 0, 0, TimeSpan.Zero),
            expiresAt: new DateTimeOffset(2026, 7, 3, 0, 5, 0, TimeSpan.Zero),
            allowedActionKinds: new[] { "mac.input.click", "mac.input.type" },
            scopeHash: "scope123",
            actionBudget: 5,
            boundEscrowDeviceId: boundEscrowDeviceId,
            attestationHashBlake3: attestationHashBlake3);
    }

    [Fact]
    public void CanonicalJson_omits_nil_bindings_and_sorts_keys()
    {
        const string expected =
            "{\"actionBudget\":5," +
            "\"allowedActionKinds\":[\"mac.input.click\",\"mac.input.type\"]," +
            "\"domain\":\"computer_use\"," +
            "\"expiresAt\":\"2026-07-03T00:05:00.000Z\"," +
            "\"issuedAt\":\"2026-07-03T00:00:00.000Z\"," +
            "\"nonce\":\"nonce-abc\"," +
            "\"schemaVersion\":1," +
            "\"scopeHash\":\"scope123\"}";

        Assert.Equal(expected, CapabilityTokenCanonicalizer.CanonicalJson(Token()));
    }

    [Fact]
    public void CanonicalJson_places_present_bindings_in_sorted_order()
    {
        const string expected =
            "{\"actionBudget\":5," +
            "\"allowedActionKinds\":[\"mac.input.click\",\"mac.input.type\"]," +
            "\"attestationHashBlake3\":\"att-hash\"," +
            "\"boundEscrowDeviceId\":\"device-9\"," +
            "\"domain\":\"computer_use\"," +
            "\"expiresAt\":\"2026-07-03T00:05:00.000Z\"," +
            "\"issuedAt\":\"2026-07-03T00:00:00.000Z\"," +
            "\"nonce\":\"nonce-abc\"," +
            "\"schemaVersion\":1," +
            "\"scopeHash\":\"scope123\"}";

        Assert.Equal(
            expected,
            CapabilityTokenCanonicalizer.CanonicalJson(
                Token(boundEscrowDeviceId: "device-9", attestationHashBlake3: "att-hash")));
    }

    [Fact]
    public void CanonicalDateString_uses_millisecond_utc_iso8601()
    {
        var date = new DateTimeOffset(2026, 7, 3, 9, 30, 15, 250, TimeSpan.FromHours(2)); // +02:00
        Assert.Equal("2026-07-03T07:30:15.250Z", CapabilityTokenCanonicalizer.CanonicalDateString(date));
    }

    [Fact]
    public void CanonicalJson_is_deterministic()
    {
        var a = CapabilityTokenCanonicalizer.CanonicalJson(Token());
        var b = CapabilityTokenCanonicalizer.CanonicalJson(Token());
        Assert.Equal(a, b);
    }

    [Fact]
    public void CanonicalJson_escapes_quotes_and_control_chars()
    {
        var token = new VirtualHidCapabilityToken(
            CapabilityTokenDomain.ComputerUse,
            nonce: "a\"b\\c\td",
            issuedAt: new DateTimeOffset(2026, 7, 3, 0, 0, 0, TimeSpan.Zero),
            expiresAt: new DateTimeOffset(2026, 7, 3, 0, 5, 0, TimeSpan.Zero),
            allowedActionKinds: new List<string> { "mac.input.click" },
            scopeHash: "s",
            actionBudget: 1);
        var json = CapabilityTokenCanonicalizer.CanonicalJson(token);
        Assert.Contains("\"nonce\":\"a\\\"b\\\\c\\td\"", json);
    }
}
