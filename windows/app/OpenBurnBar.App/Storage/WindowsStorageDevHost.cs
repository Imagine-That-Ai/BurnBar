using System;
using System.IO;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Presentation.Budget;
using OpenBurnBar.App.Presentation.ElderWand;
using OpenBurnBar.App.Presentation.Switcher;
using OpenBurnBar.Storage;
using OpenBurnBar.App.Presentation.Dashboard;
using OpenBurnBar.App.Presentation.SessionLogs;

namespace OpenBurnBar.App.Storage;

/// <summary>
/// Resolves SQLCipher database path + passphrase for Windows surfaces. Missing credentials produce
/// honest empty stores unless <c>OPENBURNBAR_SAMPLE_MODE=1</c> explicitly enables demo data.
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
        Func<IBudgetRuleStore> fallback = () => new InMemoryBudgetRuleStore(
            RuntimeDataMode.SampleModeEnabled ? seedWhenInMemory : null);

        if (path is not null && passphrase is not null)
        {
            return CreateSqlCipherOrFallback(
                "budget-rules",
                () => new SqlCipherBudgetRuleStore(path, passphrase),
                fallback);
        }

        return fallback();
    }

    public static ISwitcherProfileStore CreateSwitcherProfileStore()
    {
        var (path, passphrase) = ResolveCredentials();
        Func<ISwitcherProfileStore> fallback = () => RuntimeDataMode.SampleModeEnabled
            ? SwitcherSampleData.CreateDevHostStore()
            : new InMemorySwitcherProfileStore();

        if (path is not null && passphrase is not null)
        {
            return CreateSqlCipherOrFallback(
                "switcher-profiles",
                () => new SqlCipherSwitcherProfileStore(path, passphrase),
                fallback);
        }

        return fallback();
    }

    public static IElderWandPresetPersistence CreateElderWandPersistence()
    {
        var (path, passphrase) = ResolveCredentials();
        Func<IElderWandPresetPersistence> fallback = () => new InMemoryElderWandPersistence();

        if (path is not null && passphrase is not null)
        {
            return CreateSqlCipherOrFallback(
                "elder-wand-presets",
                () => new SqlCipherElderWandPersistence(path, passphrase),
                fallback);
        }

        return fallback();
    }

    public static ISessionLogReadSource CreateSessionLogReadSource()
    {
        var (path, passphrase) = ResolveCredentials();
        Func<ISessionLogReadSource> fallback = SessionLogEmptySource.CreateReadSource;

        if (path is not null && passphrase is not null)
        {
            return CreateSqlCipherOrFallback(
                "session-logs",
                () => new SqlCipherSessionLogReadSource(path, passphrase),
                fallback);
        }

        return fallback();
    }

    /// <summary>
    /// Reads <c>token_usage</c> aggregates when SQLCipher is configured; otherwise returns an empty summary.
    /// </summary>
    public static DashboardUsageSummary LoadDashboardUsageSummary()
    {
        var (path, passphrase) = ResolveCredentials();
        if (path is null || passphrase is null)
        {
            return EmptyDashboardUsageSummary();
        }

        try
        {
            using var store = OpenBurnBarStorage.OpenReadOnly(path, passphrase);
            var connection = store.Connection;
            double spend = TokenUsageReadSeam.SumCostCurrentUtcMonth(connection);
            long tokens = TokenUsageReadSeam.SumTotalTokens(connection);
            long sessions = TokenUsageReadSeam.CountDistinctSessions(connection);
            bool hasData = spend > 0 || tokens > 0 || sessions > 0;
            return new DashboardUsageSummary(
                spend,
                tokens,
                sessions,
                hasData,
                hasData ? DashboardUsageOrigin.Local : DashboardUsageOrigin.Empty);
        }
        catch (Exception ex)
        {
            LogStorageFallback("dashboard-summary", ex);
            return EmptyDashboardUsageSummary();
        }
    }

    private static T CreateSqlCipherOrFallback<T>(string surface, Func<T> createSqlCipher, Func<T> createFallback)
    {
        try
        {
            return createSqlCipher();
        }
        catch (Exception ex)
        {
            LogStorageFallback(surface, ex);
            return createFallback();
        }
    }

    private static void LogStorageFallback(string surface, Exception exception) =>
        System.Diagnostics.Debug.WriteLine($"OpenBurnBar storage fallback [{surface}]: {exception}");

    private static DashboardUsageSummary EmptyDashboardUsageSummary() =>
        new(0, 0, 0, HasData: false);
}
