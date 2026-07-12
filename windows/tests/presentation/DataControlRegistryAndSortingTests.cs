using System;
using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Presentation.DataControlCenter;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests;

/// <summary>
/// Real tests for the ported registry + the pure inventory sort / tier-grouping / sealed-fraction
/// passes (DataDomainRegistry.cs, DataControlSorting.cs). The Swift originals are the generated
/// <c>DataDomains.all</c> + the Table <c>sortOrder</c> re-sort + the sidebar tier filter +
/// <c>sealedFraction</c>; this pins the same matrix without a WinUI host.
/// </summary>
public sealed class DataControlRegistryAndSortingTests
{
    private static DomainRow Row(string id, EncryptionTier tier, int count = 0, long bytes = 0, string title = "T", string retention = "rolling") =>
        new(
            new DataDomain(id, title, "icon", tier, "summary",
                Array.Empty<string>(), Array.Empty<string>(), Array.Empty<string>(), Array.Empty<string>(),
                null, null, retention, Array.Empty<string>(), null, null, null, null),
            count, bytes);

    // ── Registry ─────────────────────────────────────────────────────────────────────────────

    [Fact]
    public void Registry_HasExactlyTwelveDomains_InRegistryOrder()
    {
        Assert.Equal(12, DataDomains.All.Count);
        Assert.Equal("usage_spend", DataDomains.All[0].Id);
        Assert.Equal("audit_timeline", DataDomains.All[^1].Id);
    }

    [Fact]
    public void Registry_DomainIds_AreUnique()
    {
        var ids = DataDomains.All.Select(d => d.Id).ToList();
        Assert.Equal(ids.Count, ids.Distinct(StringComparer.Ordinal).Count());
    }

    [Theory]
    [InlineData("usage_spend", EncryptionTier.ServerReadable)]
    [InlineData("conversations_chat", EncryptionTier.EndToEnd)]
    [InlineData("session_logs", EncryptionTier.EndToEnd)]
    [InlineData("pensieve", EncryptionTier.EndToEnd)]
    [InlineData("computer_use", EncryptionTier.ZeroAccess)]
    [InlineData("media", EncryptionTier.ZeroAccess)]
    [InlineData("device_trust_keys", EncryptionTier.EndToEnd)]
    [InlineData("audit_timeline", EncryptionTier.ServerReadable)]
    public void Registry_TierIsFaithful(string id, EncryptionTier expected)
    {
        Assert.Equal(expected, DataDomains.Domain(id)!.EncryptionTier);
    }

    [Fact]
    public void Registry_TierCounts_MatchSwiftRegistry()
    {
        // 6 server-readable, 2 zero-access, 4 end-to-end (from gen/DataDomains.swift):
        //   server-readable: usage_spend, provider_accounts, connected_devices, external_mcp,
        //                    entitlements_billing, audit_timeline
        //   zero-access:     computer_use, media
        //   end-to-end:      conversations_chat, session_logs, pensieve, device_trust_keys
        Assert.Equal(6, DataDomains.All.Count(d => d.EncryptionTier == EncryptionTier.ServerReadable));
        Assert.Equal(2, DataDomains.All.Count(d => d.EncryptionTier == EncryptionTier.ZeroAccess));
        Assert.Equal(4, DataDomains.All.Count(d => d.EncryptionTier == EncryptionTier.EndToEnd));
    }

    [Fact]
    public void Registry_TierRawValues_RoundTrip()
    {
        foreach (var tier in new[] { EncryptionTier.ServerReadable, EncryptionTier.ZeroAccess, EncryptionTier.EndToEnd })
        {
            Assert.Equal(tier, EncryptionTierExtensions.FromRawValue(tier.RawValue()));
        }

        Assert.Equal(EncryptionTier.EndToEnd, EncryptionTierExtensions.FromRawValue("end_to_end"));
        Assert.Null(EncryptionTierExtensions.FromRawValue("bogus"));
    }

    [Fact]
    public void Registry_ActionsAndPaths_ArePreserved()
    {
        var pensieve = DataDomains.Domain("pensieve")!;
        Assert.True(pensieve.HasAction("sync"));
        Assert.True(pensieve.HasAction("delete"));
        Assert.False(pensieve.HasAction("verify"));
        Assert.Equal("cloudvault-aesgcm-v2", pensieve.SealingScheme);
        Assert.Contains("memory_facts", pensieve.FirestorePaths);

        var sessionLogs = DataDomains.Domain("session_logs")!;
        Assert.Single(sessionLogs.StoragePaths);
        Assert.Equal("session_logs", sessionLogs.ByteSource);
    }

    [Fact]
    public void Registry_UnknownDomain_ResolvesNull() => Assert.Null(DataDomains.Domain("nope"));

    // ── Sort ─────────────────────────────────────────────────────────────────────────────────

    [Fact]
    public void Sort_ByStoredDescending_IsDefaultShape()
    {
        var rows = new[]
        {
            Row("a", EncryptionTier.ServerReadable, bytes: 10),
            Row("b", EncryptionTier.EndToEnd, bytes: 500),
            Row("c", EncryptionTier.ZeroAccess, bytes: 50),
        };

        var sorted = DataControlSorting.Sort(rows, SortDescriptor.Default);
        Assert.Equal(new[] { "b", "c", "a" }, sorted.Select(r => r.Id));
    }

    [Fact]
    public void Sort_ByRecordsAscendingThenDescending()
    {
        var rows = new[]
        {
            Row("a", EncryptionTier.ServerReadable, count: 3),
            Row("b", EncryptionTier.EndToEnd, count: 1),
            Row("c", EncryptionTier.ZeroAccess, count: 2),
        };

        var asc = DataControlSorting.Sort(rows, new SortDescriptor(SortColumn.Records, SortDirection.Ascending));
        Assert.Equal(new[] { "b", "c", "a" }, asc.Select(r => r.Id));

        var desc = DataControlSorting.Sort(rows, new SortDescriptor(SortColumn.Records, SortDirection.Descending));
        Assert.Equal(new[] { "a", "c", "b" }, desc.Select(r => r.Id));
    }

    [Fact]
    public void Sort_ByDomainTitle_IsCaseInsensitive()
    {
        var rows = new[]
        {
            Row("a", EncryptionTier.ServerReadable, title: "banana"),
            Row("b", EncryptionTier.EndToEnd, title: "Apple"),
            Row("c", EncryptionTier.ZeroAccess, title: "cherry"),
        };

        var asc = DataControlSorting.Sort(rows, new SortDescriptor(SortColumn.Domain, SortDirection.Ascending));
        Assert.Equal(new[] { "b", "a", "c" }, asc.Select(r => r.Id));
    }

    [Fact]
    public void Sort_ByRetention_Sorts()
    {
        var rows = new[]
        {
            Row("a", EncryptionTier.ServerReadable, retention: "rolling"),
            Row("b", EncryptionTier.EndToEnd, retention: "append_only"),
            Row("c", EncryptionTier.ZeroAccess, retention: "permanent"),
        };

        var asc = DataControlSorting.Sort(rows, new SortDescriptor(SortColumn.Retention, SortDirection.Ascending));
        Assert.Equal(new[] { "b", "c", "a" }, asc.Select(r => r.Id));
    }

    [Fact]
    public void Sort_IsStable_OnEqualKeys()
    {
        // All equal bytes → registry (incoming) order must be preserved.
        var rows = new[]
        {
            Row("a", EncryptionTier.ServerReadable, bytes: 100),
            Row("b", EncryptionTier.EndToEnd, bytes: 100),
            Row("c", EncryptionTier.ZeroAccess, bytes: 100),
        };

        var sorted = DataControlSorting.Sort(rows, SortDescriptor.Default);
        Assert.Equal(new[] { "a", "b", "c" }, sorted.Select(r => r.Id));
    }

    [Fact]
    public void Sort_DoesNotMutateInput()
    {
        var rows = new List<DomainRow>
        {
            Row("a", EncryptionTier.ServerReadable, bytes: 1),
            Row("b", EncryptionTier.EndToEnd, bytes: 9),
        };

        _ = DataControlSorting.Sort(rows, SortDescriptor.Default);
        Assert.Equal(new[] { "a", "b" }, rows.Select(r => r.Id));
    }

    [Fact]
    public void SortDescriptor_ToggledFor_SwitchesColumnAndDirection()
    {
        var start = SortDescriptor.Default; // Stored, Descending

        // New numeric column → descending first (biggest footprint first).
        var records = start.ToggledFor(SortColumn.Records);
        Assert.Equal(new SortDescriptor(SortColumn.Records, SortDirection.Descending), records);

        // New text column → ascending first.
        var domain = start.ToggledFor(SortColumn.Domain);
        Assert.Equal(new SortDescriptor(SortColumn.Domain, SortDirection.Ascending), domain);

        // Same column → flip direction.
        var flipped = start.ToggledFor(SortColumn.Stored);
        Assert.Equal(new SortDescriptor(SortColumn.Stored, SortDirection.Ascending), flipped);
    }

    // ── Tier grouping ────────────────────────────────────────────────────────────────────────

    [Fact]
    public void TierSections_AreInSwiftSidebarOrder_AndOmitEmptyTiers()
    {
        var rows = new[]
        {
            Row("s1", EncryptionTier.ServerReadable),
            Row("e1", EncryptionTier.EndToEnd),
            Row("e2", EncryptionTier.EndToEnd),
        };

        var sections = DataControlSorting.TierSections(rows);
        // End-to-end first, then server-readable; zero-access omitted (empty).
        Assert.Equal(new[] { EncryptionTier.EndToEnd, EncryptionTier.ServerReadable }, sections.Select(s => s.Tier));
        Assert.Equal(2, sections[0].Rows.Count);
    }

    [Fact]
    public void TierSections_OverRealRegistry_HasAllThreeTiers()
    {
        var rows = DataDomains.All.Select(d => new DomainRow(d, 0, 0)).ToList();
        var sections = DataControlSorting.TierSections(rows);
        Assert.Equal(3, sections.Count);
        Assert.Equal(EncryptionTier.EndToEnd, sections[0].Tier);
        Assert.Equal(4, sections[0].Rows.Count); // 4 end-to-end domains
        Assert.Equal(EncryptionTier.ZeroAccess, sections[1].Tier);
        Assert.Equal(EncryptionTier.ServerReadable, sections[2].Tier);
    }

    [Fact]
    public void FilterByTier_ReturnsOnlyMatching()
    {
        var rows = DataDomains.All.Select(d => new DomainRow(d, 0, 0)).ToList();
        var zero = DataControlSorting.FilterByTier(rows, EncryptionTier.ZeroAccess);
        Assert.Equal(2, zero.Count);
        Assert.All(zero, r => Assert.Equal(EncryptionTier.ZeroAccess, r.Tier));
    }

    // ── Sealed fraction ──────────────────────────────────────────────────────────────────────

    [Fact]
    public void SealedFraction_IsByteWeighted_WhenBytesReport()
    {
        var rows = new[]
        {
            Row("open", EncryptionTier.ServerReadable, bytes: 250),
            Row("sealedA", EncryptionTier.EndToEnd, bytes: 500),
            Row("sealedB", EncryptionTier.ZeroAccess, bytes: 250),
        };

        // sealed = 750 / total 1000
        Assert.Equal(0.75, DataControlSorting.SealedFraction(rows), 6);
    }

    [Fact]
    public void SealedFraction_FallsBackToCount_WhenNoBytes()
    {
        var rows = new[]
        {
            Row("open", EncryptionTier.ServerReadable, count: 3),
            Row("sealed", EncryptionTier.EndToEnd, count: 1),
        };

        // sealedCount 1 / totalCount 4
        Assert.Equal(0.25, DataControlSorting.SealedFraction(rows), 6);
    }

    [Fact]
    public void SealedFraction_IsZero_WhenEmpty()
    {
        Assert.Equal(0, DataControlSorting.SealedFraction(Array.Empty<DomainRow>()));
        Assert.Equal(0, DataControlSorting.SealedFraction(new[] { Row("x", EncryptionTier.ServerReadable) }));
    }

    [Fact]
    public void SealedFraction_IsOne_WhenAllSealed()
    {
        var rows = new[]
        {
            Row("a", EncryptionTier.EndToEnd, bytes: 10),
            Row("b", EncryptionTier.ZeroAccess, bytes: 30),
        };

        Assert.Equal(1.0, DataControlSorting.SealedFraction(rows), 6);
    }
}
