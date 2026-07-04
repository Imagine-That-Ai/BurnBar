using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.DataControlCenter;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests;

/// <summary>
/// Real tests for the DataControlCenterViewModel callable-hub orchestration ported from
/// AgentLens/Services/DataControlCenterViewModel.swift. Drives the view-model with an in-memory
/// fake hub — the Windows analog of exercising the Swift <c>@Observable @MainActor</c> original —
/// so the registry seed, usage merge, sort projection, selection, mutation-refresh loop, signed-out
/// guards, and error distillation are all proven without a WinUI host.
/// </summary>
public sealed class DataControlCenterViewModelTests
{
    // ── Fake hub ─────────────────────────────────────────────────────────────────────────────

    private sealed class FakeHub : IDataControlCallableHub
    {
        public bool IsSignedIn { get; set; } = true;
        public bool Throw { get; set; }
        public string ThrowMessage { get; set; } = "code=internal";

        public DataDomainUsageSnapshot Usage { get; set; } = DataDomainUsageSnapshot.Empty;
        public string ExportPayload { get; set; } = "{}";
        public DeleteResult Delete { get; set; } = new(3, 1);
        public RevokeResult Revoke { get; set; } = new(2, 1, 1, 4);
        public AuditVerification Verification { get; set; } = new(true, null);
        public List<RecoveryMethod> Recovery { get; } = new();
        public Queue<AuditPage> AuditPages { get; } = new();

        public int GetUsageCalls { get; private set; }
        public int DeleteCalls { get; private set; }
        public int SetupRecoveryCalls { get; private set; }

        private void Guard()
        {
            if (Throw)
            {
                throw new InvalidOperationException(ThrowMessage);
            }
        }

        public Task<DataDomainUsageSnapshot> GetUsageAsync(CancellationToken cancellationToken = default)
        {
            GetUsageCalls++;
            Guard();
            return Task.FromResult(Usage);
        }

        public Task<string> ExportAsync(IReadOnlyList<string>? domains, CancellationToken cancellationToken = default)
        {
            Guard();
            return Task.FromResult(ExportPayload);
        }

        public Task<DeleteResult> DeleteDomainAsync(string domainId, CancellationToken cancellationToken = default)
        {
            DeleteCalls++;
            Guard();
            return Task.FromResult(Delete);
        }

        public Task<IReadOnlyList<RecoveryMethod>> ListRecoveryAsync(CancellationToken cancellationToken = default)
        {
            Guard();
            return Task.FromResult<IReadOnlyList<RecoveryMethod>>(Recovery.ToList());
        }

        public Task<string> SetupRecoveryAsync(RecoveryKind method, IReadOnlyDictionary<string, object?> payload, CancellationToken cancellationToken = default)
        {
            SetupRecoveryCalls++;
            Guard();
            Recovery.Add(new RecoveryMethod("r-new", method.RawValue(), DateTimeOffset.UtcNow, false));
            return Task.FromResult("r-new");
        }

        public Task<bool> ConfirmRecoveryAsync(string recoveryId, string? verificationHash = null, CancellationToken cancellationToken = default)
        {
            Guard();
            return Task.FromResult(true);
        }

        public Task<RevokeResult> RevokeAllAsync(RevokeScope scope, CancellationToken cancellationToken = default)
        {
            Guard();
            return Task.FromResult(Revoke);
        }

        public Task<AuditPage> GetAuditLogAsync(string? cursor, int limit = 100, CancellationToken cancellationToken = default)
        {
            Guard();
            return Task.FromResult(AuditPages.Count > 0 ? AuditPages.Dequeue() : new AuditPage(Array.Empty<AuditEvent>(), null));
        }

        public Task<AuditVerification> VerifyAuditLogAsync(CancellationToken cancellationToken = default)
        {
            Guard();
            return Task.FromResult(Verification);
        }
    }

    private static DataDomainUsageSnapshot Snapshot(AccountPlanTier tier, params (string Id, int Count, long Bytes)[] usage) =>
        new(
            tier,
            new PensieveLimits(10, 5000, 8_000_000),
            usage.ToDictionary(u => u.Id, u => new DomainUsage(u.Count, u.Bytes), StringComparer.Ordinal));

    // ── Seed + guards ────────────────────────────────────────────────────────────────────────

    [Fact]
    public void Constructor_SeedsAllTwelveRegistryDomains_AtZero()
    {
        var vm = new DataControlCenterViewModel();
        Assert.Equal(12, vm.Rows.Count);
        Assert.All(vm.Rows, r => Assert.Equal(0, r.Count));
        Assert.Equal(3, vm.TierSections.Count);
    }

    [Fact]
    public async Task SignedOut_RefreshUsage_SetsCalmSignInCopy()
    {
        var vm = new DataControlCenterViewModel(new FakeHub { IsSignedIn = false });
        await vm.RefreshUsageAsync();
        Assert.Equal("Sign in to OpenBurnBar to view your data.", vm.UsageError);
        Assert.True(vm.HasUsageError);
    }

    [Fact]
    public async Task SignedOut_MutationsAreGuarded_WithSpecificCopy()
    {
        var vm = new DataControlCenterViewModel(new FakeHub { IsSignedIn = false });

        Assert.Null(await vm.ExportDataAsync(null));
        Assert.Equal("Sign in to OpenBurnBar to export your data.", vm.ActionError);

        Assert.Null(await vm.DeleteDomainAsync("media"));
        Assert.Equal("Sign in to OpenBurnBar to delete your data.", vm.ActionError);

        Assert.Null(await vm.RevokeAllAccessAsync(RevokeScope.All));
        Assert.Equal("Sign in to OpenBurnBar to revoke access.", vm.ActionError);

        Assert.Null(await vm.SetupRecoveryAsync(RecoveryKind.RecoveryKey, new Dictionary<string, object?>()));
        Assert.Equal("Sign in to OpenBurnBar to set up recovery.", vm.ActionError);
    }

    // ── Usage merge + basin ──────────────────────────────────────────────────────────────────

    [Fact]
    public async Task RefreshUsage_MergesSnapshot_IntoRegistryOrderedRows()
    {
        var hub = new FakeHub
        {
            Usage = Snapshot(AccountPlanTier.Ultra, ("session_logs", 42, 1_000_000), ("media", 3, 500_000)),
        };
        var vm = new DataControlCenterViewModel(hub);

        await vm.RefreshUsageAsync();

        Assert.Equal(AccountPlanTier.Ultra, vm.Tier);
        Assert.Equal(12, vm.Rows.Count); // still all 12, missing usage → zero
        Assert.Equal(42, vm.Row("session_logs")!.Count);
        Assert.Equal(500_000, vm.Row("media")!.Bytes);
        Assert.Equal(0, vm.Row("usage_spend")!.Count);
        Assert.Equal(new PensieveLimits(10, 5000, 8_000_000), vm.PensieveLimits);
        Assert.False(vm.IsLoadingUsage);
    }

    [Fact]
    public async Task SealedFraction_And_BasinCaption_TrackSnapshot()
    {
        // session_logs (E2E) 800000 sealed, usage_spend (server) 200000 open → 80% sealed.
        var hub = new FakeHub
        {
            Usage = Snapshot(AccountPlanTier.Pro, ("session_logs", 5, 800_000), ("usage_spend", 5, 200_000)),
        };
        var vm = new DataControlCenterViewModel(hub);
        await vm.RefreshUsageAsync();

        Assert.Equal(0.8, vm.SealedFraction, 6);
        Assert.Equal("80% sealed", vm.BasinCaption);
    }

    // ── Sort + selection ─────────────────────────────────────────────────────────────────────

    [Fact]
    public async Task SortedRows_ReflectDescriptor_AndApplySortToggles()
    {
        var hub = new FakeHub
        {
            Usage = Snapshot(AccountPlanTier.Pro, ("usage_spend", 1, 10), ("session_logs", 1, 900), ("media", 1, 50)),
        };
        var vm = new DataControlCenterViewModel(hub);
        await vm.RefreshUsageAsync();

        // The VM always holds all 12 registry rows (9 have zero bytes). Default: Stored descending
        // → biggest first; the zero-byte rows sink to the bottom in registry order.
        Assert.Equal("session_logs", vm.SortedRows[0].Id);   // 900 bytes, biggest
        Assert.Equal(12, vm.SortedRows.Count);

        vm.ApplySort(SortColumn.Stored); // same column → flip to ascending
        Assert.Equal(SortDirection.Ascending, vm.SortDescriptor.Direction);
        Assert.Equal(0, vm.SortedRows[0].Bytes);             // a zero-byte domain floats up
        Assert.Equal("session_logs", vm.SortedRows[^1].Id);  // biggest now last
    }

    [Fact]
    public void SelectedRow_ResolvesFromSelectedId()
    {
        var vm = new DataControlCenterViewModel();
        Assert.Null(vm.SelectedRow);
        vm.SelectedId = "pensieve";
        Assert.Equal("pensieve", vm.SelectedRow!.Id);
    }

    // ── Mutation → refresh loop ──────────────────────────────────────────────────────────────

    [Fact]
    public async Task DeleteDomain_ReturnsTally_AndRefreshesUsage()
    {
        var hub = new FakeHub { Delete = new DeleteResult(7, 2) };
        var vm = new DataControlCenterViewModel(hub);

        var result = await vm.DeleteDomainAsync("media");

        Assert.Equal(new DeleteResult(7, 2), result);
        Assert.Equal(1, hub.DeleteCalls);
        Assert.Equal(1, hub.GetUsageCalls); // delete triggers a usage refresh
        Assert.False(vm.IsMutating);
    }

    [Fact]
    public async Task Export_ReturnsPayload()
    {
        var hub = new FakeHub { ExportPayload = "{\"ok\":true}" };
        var vm = new DataControlCenterViewModel(hub);

        var json = await vm.ExportDataAsync(new[] { "usage_spend" });
        Assert.Equal("{\"ok\":true}", json);
        Assert.False(vm.IsExporting);
    }

    [Fact]
    public async Task Recovery_SetupThenConfirm_RefreshesMethods()
    {
        var hub = new FakeHub();
        var vm = new DataControlCenterViewModel(hub);

        var id = await vm.SetupRecoveryAsync(RecoveryKind.RecoveryKey, new Dictionary<string, object?> { ["k"] = "v" });
        Assert.Equal("r-new", id);
        Assert.Equal(1, hub.SetupRecoveryCalls);
        Assert.Single(vm.RecoveryMethods);

        Assert.True(await vm.ConfirmRecoveryAsync("r-new", "hash"));
    }

    [Fact]
    public async Task Panic_Revoke_ReturnsTally_AndRefreshes()
    {
        var hub = new FakeHub { Revoke = new RevokeResult(5, 3, 2, 6) };
        var vm = new DataControlCenterViewModel(hub);

        var result = await vm.RevokeAllAccessAsync(RevokeScope.All);
        Assert.Equal(new RevokeResult(5, 3, 2, 6), result);
        Assert.Equal(1, hub.GetUsageCalls);
    }

    // ── Audit ────────────────────────────────────────────────────────────────────────────────

    [Fact]
    public async Task AuditLog_ResetThenPage_AppendsAndTracksCursor()
    {
        var hub = new FakeHub();
        hub.AuditPages.Enqueue(new AuditPage(new[]
        {
            new AuditEvent(2, DateTimeOffset.UtcNow, "you", "delete", "media", "a", "b"),
            new AuditEvent(1, DateTimeOffset.UtcNow, "you", "export", "usage_spend", "c", "d"),
        }, "cursor-1"));
        hub.AuditPages.Enqueue(new AuditPage(new[]
        {
            new AuditEvent(0, DateTimeOffset.UtcNow, "system", "seed", "audit_timeline", "e", "f"),
        }, null));

        var vm = new DataControlCenterViewModel(hub);

        await vm.RefreshAuditLogAsync(reset: true);
        Assert.Equal(2, vm.AuditEvents.Count);
        Assert.True(vm.HasMoreAudit);

        await vm.RefreshAuditLogAsync(reset: false);
        Assert.Equal(3, vm.AuditEvents.Count); // appended
        Assert.False(vm.HasMoreAudit);         // cursor exhausted
    }

    [Fact]
    public async Task VerifyAuditLog_SetsVerification()
    {
        var hub = new FakeHub { Verification = new AuditVerification(false, 7) };
        var vm = new DataControlCenterViewModel(hub);

        await vm.VerifyAuditLogAsync();
        Assert.NotNull(vm.AuditVerification);
        Assert.False(vm.AuditVerification!.Value.Valid);
        Assert.Equal(7, vm.AuditVerification.Value.BrokenAt);
    }

    // ── Errors ───────────────────────────────────────────────────────────────────────────────

    [Fact]
    public async Task ThrowingHub_DistillsUsageError()
    {
        var hub = new FakeHub { Throw = true, ThrowMessage = "code=internal boom" };
        var vm = new DataControlCenterViewModel(hub);

        await vm.RefreshUsageAsync();
        Assert.Equal("We couldn't complete that securely. Try again in a minute.", vm.UsageError);
        Assert.False(vm.IsLoadingUsage);
    }

    [Fact]
    public async Task ThrowingHub_DistillsActionError_OnDelete()
    {
        var hub = new FakeHub { Throw = true, ThrowMessage = "PERMISSION_DENIED" };
        var vm = new DataControlCenterViewModel(hub);

        Assert.Null(await vm.DeleteDomainAsync("media"));
        Assert.Equal("This action isn't available for your account yet.", vm.ActionError);
        Assert.False(vm.IsMutating);
    }
}
