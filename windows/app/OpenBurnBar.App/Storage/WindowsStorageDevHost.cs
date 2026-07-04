using System;
using System.IO;
using OpenBurnBar.App.Presentation.Budget;
using OpenBurnBar.App.Presentation.ElderWand;
using OpenBurnBar.App.Presentation.Switcher;
using OpenBurnBar.Storage;
using OpenBurnBar.App.Presentation.Dashboard;
using OpenBurnBar.App.Presentation.SessionLogs;

namespace OpenBurnBar.App.Storage;

/// <summary>
/// Resolves SQLCipher database path + passphrase for dev-host surfaces, with documented
/// <see cref="InMemoryBudgetRuleStore"/> / sample fallbacks when unset.
/// </summary>
internal static class WindowsStorageDevHost
{
    /// <summary>
    /// Optional override for integration tests or a configured Windows host
    /// (<c>OPENBURNBAR_SQLCIPHER_PATH</c> + <c>OPENBURNBAR_SQLCIPHER_PASSPHRASE</c>).
    /// </summary>
    public static (string? Path, string? Passphrase) ResolveCredentials()
    {
        var config = OpenBurnBar.App.Configuration.AppConfiguration.Current;
        string? path = config.EffectiveSqlCipherDbPath();
        string? passphrase = config.EffectiveSqlCipherPassphrase();
        if (!string.IsNullOrWhiteSpace(path) && !string.IsNullOrWhiteSpace(passphrase) && File.Exists(path))
        {
            return (path, passphrase);
        }

        return (null, null);
    }

    public static IBudgetRuleStore CreateBudgetRuleStore(System.Collections.Generic.IEnumerable<BudgetRule>? seedWhenInMemory = null)
    {
        var (path, passphrase) = ResolveCredentials();
        if (path is not null && passphrase is not null)
        {
            return new SqlCipherBudgetRuleStore(path, passphrase);
        }

        return new InMemoryBudgetRuleStore(seedWhenInMemory);
    }

    public static ISwitcherProfileStore CreateSwitcherProfileStore()
    {
        var (path, passphrase) = ResolveCredentials();
        if (path is not null && passphrase is not null)
        {
            return new SqlCipherSwitcherProfileStore(path, passphrase);
        }

        return SwitcherSampleData.CreateDevHostStore();
    }

    public static IElderWandPresetPersistence CreateElderWandPersistence()
    {
        var (path, passphrase) = ResolveCredentials();
        if (path is not null && passphrase is not null)
        {
            return new SqlCipherElderWandPersistence(path, passphrase);
        }

        return new InMemoryElderWandPersistence();
    }

    public static ISessionLogReadSource CreateSessionLogReadSource()
    {
        var (path, passphrase) = ResolveCredentials();
        if (path is not null && passphrase is not null)
        {
            return new SqlCipherSessionLogReadSource(path, passphrase);
        }

        return SessionLogSampleData.CreateReadSource();
    }

    /// <summary>
    /// Reads <c>token_usage</c> aggregates when SQLCipher is configured; otherwise returns an empty summary.
    /// </summary>
    public static DashboardUsageSummary LoadDashboardUsageSummary()
    {
        var (path, passphrase) = ResolveCredentials();
        if (path is null || passphrase is null)
        {
            return new DashboardUsageSummary(0, 0, 0, HasData: false);
        }

        using var store = OpenBurnBarStorage.OpenReadOnly(path, passphrase);
        var connection = store.Connection;
        double spend = TokenUsageReadSeam.SumCostCurrentUtcMonth(connection);
        long tokens = TokenUsageReadSeam.SumTotalTokens(connection);
        long sessions = TokenUsageReadSeam.CountDistinctSessions(connection);
        bool hasData = spend > 0 || tokens > 0 || sessions > 0;
        return new DashboardUsageSummary(spend, tokens, sessions, hasData);
    }
}