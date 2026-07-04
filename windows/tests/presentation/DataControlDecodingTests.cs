using System;
using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Presentation.DataControlCenter;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests;

/// <summary>
/// Real tests for the callable-payload decode + user-facing error distillation ported from
/// AgentLens/Services/DataControlCenterViewModel.swift (applyUsage / parseAuditEvent / parseDate /
/// intValue / userFacing). Proves the shared decode path the real FirebaseFunctions Windows
/// adapter will use produces the same typed snapshots and the same calm copy.
/// </summary>
public sealed class DataControlDecodingTests
{
    private static Dictionary<string, object?> Obj(params (string Key, object? Value)[] pairs) =>
        pairs.ToDictionary(p => p.Key, p => p.Value, StringComparer.Ordinal);

    // ── Usage snapshot ───────────────────────────────────────────────────────────────────────

    [Fact]
    public void UsageParser_DecodesTierLimitsAndPerDomainUsage()
    {
        var payload = Obj(
            ("tier", "pro"),
            ("limits", Obj(("pensieve", Obj(("sources", 12L), ("chunks", 3400L), ("bytes", 9_000_000L))))),
            ("domains", new List<object?>
            {
                Obj(("id", "session_logs"), ("count", 42L), ("bytes", 1_048_576L)),
                Obj(("id", "pensieve"), ("count", 100.0), ("bytes", "2048")),
            }));

        var snap = DataDomainUsageParser.Parse(payload);

        Assert.Equal(AccountPlanTier.Pro, snap.Tier);
        Assert.Equal(new PensieveLimits(12, 3400, 9_000_000), snap.PensieveLimits);
        Assert.Equal(new DomainUsage(42, 1_048_576), snap.UsageById["session_logs"]);
        // count from double, bytes from string — both coerced.
        Assert.Equal(new DomainUsage(100, 2048), snap.UsageById["pensieve"]);
    }

    [Fact]
    public void UsageParser_NullOrEmpty_YieldsFreeTierEmpty()
    {
        Assert.Equal(DataDomainUsageSnapshot.Empty, DataDomainUsageParser.Parse(null));

        var empty = DataDomainUsageParser.Parse(Obj());
        Assert.Equal(AccountPlanTier.Free, empty.Tier);
        Assert.Equal(PensieveLimits.Empty, empty.PensieveLimits);
        Assert.Empty(empty.UsageById);
    }

    [Fact]
    public void UsageParser_SkipsDomainRowsMissingId()
    {
        var payload = Obj(("domains", new List<object?>
        {
            Obj(("count", 5L)),                       // no id → skipped
            Obj(("id", "media"), ("count", 7L)),
        }));

        var snap = DataDomainUsageParser.Parse(payload);
        Assert.Single(snap.UsageById);
        Assert.Equal(7, snap.UsageById["media"].Count);
    }

    // ── Audit + recovery ─────────────────────────────────────────────────────────────────────

    [Fact]
    public void AuditPage_ParsesEvents_AndCursor_SkippingSeqless()
    {
        var payload = Obj(
            ("events", new List<object?>
            {
                Obj(("seq", 1L), ("actor", "you"), ("action", "export"), ("domain", "usage_spend"),
                    ("prevHash", "aa"), ("hash", "bb"), ("ts", "2026-07-03T10:00:00Z")),
                Obj(("actor", "orphan")), // no seq → skipped
            }),
            ("nextCursor", "cursor-2"));

        var page = GovernanceDecoding.ParseAuditPage(payload);

        Assert.Single(page.Events);
        Assert.Equal("cursor-2", page.NextCursor);
        var evt = page.Events[0];
        Assert.Equal(1, evt.Seq);
        Assert.Equal("you", evt.Actor);
        Assert.NotNull(evt.Timestamp);
    }

    [Fact]
    public void AuditEvent_MissingFields_DefaultToEmDash()
    {
        var evt = GovernanceDecoding.ParseAuditEvent(Obj(("seq", 9L)));
        Assert.NotNull(evt);
        Assert.Equal("—", evt!.Actor);
        Assert.Equal("—", evt.Action);
        Assert.Equal("—", evt.Domain);
        Assert.Equal(string.Empty, evt.Hash);
    }

    [Fact]
    public void RecoveryMethods_ParseAndRequireIdAndKind()
    {
        var payload = Obj(("methods", new List<object?>
        {
            Obj(("recoveryId", "r1"), ("kind", "recovery_key"), ("confirmed", true), ("createdAt", "2026-07-01T00:00:00Z")),
            Obj(("recoveryId", "r2"), ("kind", "recovery_contact"), ("confirmed", false)),
            Obj(("kind", "recovery_key")), // no id → dropped
        }));

        var methods = GovernanceDecoding.ParseRecoveryMethods(payload);
        Assert.Equal(2, methods.Count);
        Assert.True(methods[0].Confirmed);
        Assert.NotNull(methods[0].CreatedAt);
        Assert.True(methods[1].IsRecoveryContact);
    }

    // ── Value coercion ───────────────────────────────────────────────────────────────────────

    [Theory]
    [InlineData(5L, 5)]
    [InlineData(5, 5)]
    [InlineData(5.9, 5)]
    [InlineData("7", 7)]
    [InlineData("nope", 0)]
    [InlineData(null, 0)]
    public void CallableValue_Int_Coerces(object? raw, int expected) => Assert.Equal(expected, CallableValue.Int(raw));

    [Fact]
    public void CallableValue_Date_ParsesIsoAndEpochMillis()
    {
        Assert.NotNull(CallableValue.Date("2026-07-03T12:34:56Z"));
        Assert.NotNull(CallableValue.Date("2026-07-03T12:34:56.789Z"));
        var epoch = CallableValue.Date(1_700_000_000_000L);
        Assert.Equal(DateTimeOffset.FromUnixTimeMilliseconds(1_700_000_000_000L), epoch);
        Assert.Null(CallableValue.Date("not-a-date"));
    }

    // ── Error distillation ───────────────────────────────────────────────────────────────────

    [Theory]
    [InlineData("internal", "We couldn't complete that securely. Try again in a minute.")]
    [InlineData("Error: code=internal, details=…", "We couldn't complete that securely. Try again in a minute.")]
    [InlineData("signBlob permission failed", "We couldn't complete that securely. Try again in a minute.")]
    [InlineData("UNAUTHENTICATED", "Sign in again to manage your data.")]
    [InlineData("permission denied on resource", "This action isn't available for your account yet.")]
    [InlineData("The network connection was lost", "Network connection failed. Try again when you're online.")]
    [InlineData("request timed out", "Network connection failed. Try again when you're online.")]
    public void UserFacing_MapsKnownFailures(string raw, string expected) =>
        Assert.Equal(expected, DataControlErrorMapping.UserFacing(raw));

    [Fact]
    public void UserFacing_EmptyOrWhitespace_UsesFallback()
    {
        Assert.Equal(DataControlErrorMapping.Fallback, DataControlErrorMapping.UserFacing(""));
        Assert.Equal(DataControlErrorMapping.Fallback, DataControlErrorMapping.UserFacing("   "));
        Assert.Equal(DataControlErrorMapping.Fallback, DataControlErrorMapping.UserFacing((string?)null));
    }

    [Fact]
    public void UserFacing_UnknownMessage_PassesThroughTrimmed()
    {
        Assert.Equal("Disk full", DataControlErrorMapping.UserFacing("  Disk full  "));
    }

    [Fact]
    public void UserFacing_HonorsFriendlyErrorFirst()
    {
        Assert.Equal("Sign in to OpenBurnBar to manage your data.",
            DataControlErrorMapping.UserFacing(new NotSignedInException()));
        Assert.Equal("The server returned an unexpected response.",
            DataControlErrorMapping.UserFacing(new MalformedResponseException()));
    }
}
