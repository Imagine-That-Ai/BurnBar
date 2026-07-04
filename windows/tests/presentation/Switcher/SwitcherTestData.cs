using System;
using System.Collections.Generic;
using OpenBurnBar.App.Presentation.Switcher;

namespace OpenBurnBar.App.Presentation.Tests.Switcher;

/// <summary>Factory helpers for the switcher portable-logic tests.</summary>
internal static class SwitcherTestData
{
    public static readonly DateTimeOffset Now = new(2026, 7, 22, 12, 0, 0, TimeSpan.Zero);

    public static SwitcherProfileRecord Cli(
        string id,
        SwitcherCLIProfileType type,
        string? account = null,
        string? label = null,
        bool disabled = false,
        DateTimeOffset? exhaustedUntil = null,
        IReadOnlyList<string>? args = null,
        IReadOnlyList<string>? env = null,
        string? workingDir = null)
    {
        return new SwitcherProfileRecord(
            Id: id,
            TargetKind: SwitcherProfileTargetKind.Cli,
            SortKey: 0,
            CliType: type,
            CliMetadata: new SwitcherCLIProfileMetadata(
                WorkingDirectory: workingDir,
                AdditionalArgs: args,
                EnvKeysToPass: env,
                DisplayLabel: label,
                AccountDescription: account,
                ExhaustedUntil: exhaustedUntil,
                IsDisabled: disabled));
    }

    public static SwitcherProfileRecord Browser(
        string id,
        SwitcherBrowserProfileType type,
        string profileIdentifier = "Default",
        string? label = null,
        string? email = null,
        string? providerIdentifier = null,
        bool disabled = false,
        IReadOnlyList<BrowserServiceIdentity>? services = null)
    {
        return new SwitcherProfileRecord(
            Id: id,
            TargetKind: SwitcherProfileTargetKind.Browser,
            SortKey: 0,
            BrowserType: type,
            BrowserMetadata: new SwitcherBrowserProfileMetadata(
                ProfileIdentifier: profileIdentifier,
                DisplayLabel: label,
                AccountEmail: email,
                ProviderIdentifier: providerIdentifier,
                ServiceIdentities: services,
                IsDisabled: disabled));
    }

    public static InMemorySwitcherProfileStore Store(
        IEnumerable<SwitcherProfileRecord>? seed = null,
        string? active = null)
        => new(seed, active, () => Now);

    public static SwitcherSettingsViewModel ViewModel(
        InMemorySwitcherProfileStore store,
        int startId = 1000)
    {
        int counter = startId;
        var vm = new SwitcherSettingsViewModel(
            store,
            now: () => Now,
            idFactory: () => $"gen-{counter++}");
        vm.Load();
        return vm;
    }
}
