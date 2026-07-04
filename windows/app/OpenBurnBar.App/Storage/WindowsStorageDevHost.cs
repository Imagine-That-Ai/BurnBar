using System;
using System.IO;
using OpenBurnBar.App.Presentation.Budget;
using OpenBurnBar.App.Presentation.ElderWand;
using OpenBurnBar.App.Presentation.Switcher;
using OpenBurnBar.Storage;

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
        string? path = Environment.GetEnvironmentVariable("OPENBURNBAR_SQLCIPHER_PATH");
        string? passphrase = Environment.GetEnvironmentVariable("OPENBURNBAR_SQLCIPHER_PASSPHRASE");
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
}