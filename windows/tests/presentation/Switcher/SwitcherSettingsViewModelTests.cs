using System;
using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Presentation.Switcher;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Switcher;

/// <summary>
/// Pins the account-switcher state machine ported from
/// AccountSwitcherSettingsView+DataOperations.swift: add profile, switch active, drain-target
/// routing, pause/resume guards, delete fallback, and within-group reordering.
/// </summary>
public sealed class SwitcherSettingsViewModelTests
{
    [Fact]
    public void ResolveActiveProfileId_KeepsValidEnabled_ElseFirstEnabled()
    {
        var profiles = new[]
        {
            SwitcherTestData.Cli("a", SwitcherCLIProfileType.Claude, account: "a@x", disabled: true),
            SwitcherTestData.Cli("b", SwitcherCLIProfileType.Claude, account: "b@x"),
            SwitcherTestData.Cli("c", SwitcherCLIProfileType.Claude, account: "c@x"),
        };

        // Stored active is disabled → falls back to first enabled ("b").
        Assert.Equal("b", SwitcherSettingsViewModel.ResolveActiveProfileId(new SwitcherActiveProfileState("a"), profiles));
        // Stored active is valid+enabled → kept.
        Assert.Equal("c", SwitcherSettingsViewModel.ResolveActiveProfileId(new SwitcherActiveProfileState("c"), profiles));
        // No stored active → first enabled.
        Assert.Equal("b", SwitcherSettingsViewModel.ResolveActiveProfileId(new SwitcherActiveProfileState(null), profiles));
    }

    [Fact]
    public void CreateProfile_FirstProfile_BecomesActive()
    {
        var store = SwitcherTestData.Store();
        var vm = SwitcherTestData.ViewModel(store);

        var form = new SwitcherProfileForm
        {
            TargetKind = SwitcherProfileTargetKind.Cli,
            CliType = SwitcherCLIProfileType.Claude,
            Name = "First",
        };

        var result = vm.CreateProfile(form);

        Assert.True(result.IsValid);
        Assert.Equal(1, vm.ProfileCount);
        Assert.Equal(vm.Profiles[0].Id, vm.ActiveProfileId);
        Assert.True(vm.HasActiveProfile);
    }

    [Fact]
    public void CreateProfile_SecondProfile_DoesNotChangeActive()
    {
        var store = SwitcherTestData.Store(new[]
        {
            SwitcherTestData.Cli("a", SwitcherCLIProfileType.Claude, account: "a@x"),
        }, active: "a");
        var vm = SwitcherTestData.ViewModel(store);

        vm.CreateProfile(new SwitcherProfileForm
        {
            TargetKind = SwitcherProfileTargetKind.Cli,
            CliType = SwitcherCLIProfileType.Codex,
            Name = "Second",
        });

        Assert.Equal(2, vm.ProfileCount);
        Assert.Equal("a", vm.ActiveProfileId);
    }

    [Fact]
    public void CreateProfile_DuplicateName_Rejected_NotPersisted()
    {
        var store = SwitcherTestData.Store(new[]
        {
            SwitcherTestData.Cli("a", SwitcherCLIProfileType.Claude, label: "Work"),
        });
        var vm = SwitcherTestData.ViewModel(store);

        var result = vm.CreateProfile(new SwitcherProfileForm
        {
            TargetKind = SwitcherProfileTargetKind.Cli,
            CliType = SwitcherCLIProfileType.Codex,
            Name = "work",
        });

        Assert.False(result.IsValid);
        Assert.Equal("A profile with this name already exists", result.DuplicateError);
        Assert.Equal(1, vm.ProfileCount);
    }

    [Fact]
    public void SetActiveProfile_UpdatesActiveAndStore()
    {
        var store = SwitcherTestData.Store(new[]
        {
            SwitcherTestData.Cli("a", SwitcherCLIProfileType.Claude, account: "a@x"),
            SwitcherTestData.Cli("b", SwitcherCLIProfileType.Codex, account: "b@x"),
        }, active: "a");
        var vm = SwitcherTestData.ViewModel(store);

        vm.SetActiveProfile(vm.Profiles.Single(p => p.Id == "b"));

        Assert.Equal("b", vm.ActiveProfileId);
        Assert.Equal("b", store.FetchActiveProfileState().ActiveProfileId);
    }

    [Fact]
    public void SetDrainTarget_IsPerProvider_LeavesOtherProvidersUntouched()
    {
        var store = SwitcherTestData.Store(new[]
        {
            SwitcherTestData.Cli("claudeA", SwitcherCLIProfileType.Claude, account: "a@x"),
            SwitcherTestData.Cli("claudeB", SwitcherCLIProfileType.Claude, account: "b@x"),
            SwitcherTestData.Cli("codexA", SwitcherCLIProfileType.Codex, account: "c@x"),
        });
        var vm = SwitcherTestData.ViewModel(store);

        vm.SetDrainTarget(vm.Profiles.Single(p => p.Id == "claudeB"), SwitcherCLIProfileType.Claude);
        vm.SetDrainTarget(vm.Profiles.Single(p => p.Id == "codexA"), SwitcherCLIProfileType.Codex);

        Assert.Equal("claudeB", vm.DrainTargets["claude-code"]);
        Assert.Equal("codexA", vm.DrainTargets["codex"]);

        // Re-routing Claude does not disturb Codex.
        vm.SetDrainTarget(vm.Profiles.Single(p => p.Id == "claudeA"), SwitcherCLIProfileType.Claude);
        Assert.Equal("claudeA", vm.DrainTargets["claude-code"]);
        Assert.Equal("codexA", vm.DrainTargets["codex"]);
    }

    [Fact]
    public void ToggleDisabled_RefusesToPauseLastEnabledInGroup()
    {
        var store = SwitcherTestData.Store(new[]
        {
            SwitcherTestData.Cli("only", SwitcherCLIProfileType.Claude, account: "a@x"),
        });
        var vm = SwitcherTestData.ViewModel(store);
        var group = vm.CliGroups.Single();

        vm.ToggleDisabled(vm.Profiles.Single(p => p.Id == "only"), group);

        Assert.False(vm.Profiles.Single(p => p.Id == "only").IsDisabled);
        Assert.NotNull(vm.ErrorMessage);
        Assert.Contains("Keep at least one", vm.ErrorMessage);
    }

    [Fact]
    public void ToggleDisabled_PausingActive_ReassignsActiveToEnabledPeer()
    {
        var store = SwitcherTestData.Store(new[]
        {
            SwitcherTestData.Cli("a", SwitcherCLIProfileType.Claude, account: "a@x"),
            SwitcherTestData.Cli("b", SwitcherCLIProfileType.Claude, account: "b@x"),
        }, active: "a");
        var vm = SwitcherTestData.ViewModel(store);
        var group = vm.CliGroups.Single();

        Assert.Equal("a", vm.ActiveProfileId);
        vm.ToggleDisabled(vm.Profiles.Single(p => p.Id == "a"), group);

        Assert.True(vm.Profiles.Single(p => p.Id == "a").IsDisabled);
        Assert.Equal("b", vm.ActiveProfileId);
    }

    [Fact]
    public void DeleteProfile_Active_PicksEnabledFallback()
    {
        var store = SwitcherTestData.Store(new[]
        {
            SwitcherTestData.Cli("a", SwitcherCLIProfileType.Claude, account: "a@x"),
            SwitcherTestData.Cli("b", SwitcherCLIProfileType.Codex, account: "b@x"),
        }, active: "a");
        var vm = SwitcherTestData.ViewModel(store);

        vm.DeleteProfile(vm.Profiles.Single(p => p.Id == "a"));

        Assert.Equal(1, vm.ProfileCount);
        Assert.Equal("b", vm.ActiveProfileId);
    }

    [Fact]
    public void MakePrimary_MovesProfileToFrontOfGroup_PreservingOtherGroups()
    {
        var store = SwitcherTestData.Store(new[]
        {
            SwitcherTestData.Cli("claudeA", SwitcherCLIProfileType.Claude, account: "a@x"),
            SwitcherTestData.Cli("claudeB", SwitcherCLIProfileType.Claude, account: "b@x"),
            SwitcherTestData.Cli("codexA", SwitcherCLIProfileType.Codex, account: "c@x"),
        });
        var vm = SwitcherTestData.ViewModel(store);
        var claudeGroup = vm.CliGroups.Single(g => g.Key == "claude");

        vm.MakePrimary(vm.Profiles.Single(p => p.Id == "claudeB"), claudeGroup);

        var refreshedClaude = vm.CliGroups.Single(g => g.Key == "claude");
        Assert.Equal(new[] { "claudeB", "claudeA" }, refreshedClaude.Profiles.Select(p => p.Profile.Id).ToArray());
        // Codex group untouched.
        Assert.Equal(new[] { "codexA" }, vm.CliGroups.Single(g => g.Key == "codex").Profiles.Select(p => p.Profile.Id).ToArray());
    }

    [Fact]
    public void MoveWithinGroup_Down_SwapsAdjacent()
    {
        var store = SwitcherTestData.Store(new[]
        {
            SwitcherTestData.Cli("a", SwitcherCLIProfileType.Claude, account: "a@x"),
            SwitcherTestData.Cli("b", SwitcherCLIProfileType.Claude, account: "b@x"),
            SwitcherTestData.Cli("c", SwitcherCLIProfileType.Claude, account: "c@x"),
        });
        var vm = SwitcherTestData.ViewModel(store);
        var group = vm.CliGroups.Single();

        vm.MoveWithinGroup(vm.Profiles.Single(p => p.Id == "a"), group, moveUp: false);

        Assert.Equal(
            new[] { "b", "a", "c" },
            vm.CliGroups.Single().Profiles.Select(p => p.Profile.Id).ToArray());
    }

    [Fact]
    public void SwapWithinGroup_SwapsPrimaryAndFirstReserve()
    {
        var store = SwitcherTestData.Store(new[]
        {
            SwitcherTestData.Cli("a", SwitcherCLIProfileType.Claude, account: "a@x"),
            SwitcherTestData.Cli("b", SwitcherCLIProfileType.Claude, account: "b@x"),
        });
        var vm = SwitcherTestData.ViewModel(store);
        var group = vm.CliGroups.Single();

        vm.SwapWithinGroup(vm.Profiles.Single(p => p.Id == "a"), group);

        Assert.Equal(
            new[] { "b", "a" },
            vm.CliGroups.Single().Profiles.Select(p => p.Profile.Id).ToArray());
    }

    [Fact]
    public void Mode_FiltersVisibleGroups()
    {
        var store = SwitcherTestData.Store(new[]
        {
            SwitcherTestData.Cli("a", SwitcherCLIProfileType.Claude, account: "a@x"),
            SwitcherTestData.Browser("b", SwitcherBrowserProfileType.Chrome, email: "me@x"),
        });
        var vm = SwitcherTestData.ViewModel(store);

        vm.Mode = SwitcherViewMode.CliOnly;
        Assert.All(vm.Groups, g => Assert.True(g.IsCli));

        vm.Mode = SwitcherViewMode.BrowserOnly;
        Assert.All(vm.Groups, g => Assert.True(g.IsBrowser));

        vm.Mode = SwitcherViewMode.All;
        Assert.Equal(2, vm.Groups.Count);
    }

    [Fact]
    public void Sections_SplitCliAndBrowser_AndRowsCarryTheirGroup()
    {
        var store = SwitcherTestData.Store(new[]
        {
            SwitcherTestData.Cli("a", SwitcherCLIProfileType.Claude, account: "a@x"),
            SwitcherTestData.Cli("b", SwitcherCLIProfileType.Claude, account: "b@x"),
            SwitcherTestData.Browser("c", SwitcherBrowserProfileType.Chrome, email: "me@x"),
        });
        var vm = SwitcherTestData.ViewModel(store);

        var cli = Assert.Single(vm.CliSections);
        Assert.Equal("claude", cli.Key);
        Assert.Equal(2, cli.Rows.Count);
        Assert.Equal("Add Account", cli.AddButtonLabel);
        Assert.True(cli.CanCollapse);
        Assert.All(cli.Rows, r => Assert.Same(cli.Group, r.Group));

        var browser = Assert.Single(vm.BrowserSections);
        Assert.Equal("chrome", browser.Key);
        Assert.Single(browser.Rows);
        Assert.False(browser.CanCollapse);
    }

    [Fact]
    public void SetActiveProfile_RefreshesSectionRowActiveState()
    {
        var store = SwitcherTestData.Store(new[]
        {
            SwitcherTestData.Cli("a", SwitcherCLIProfileType.Claude, account: "a@x"),
            SwitcherTestData.Cli("b", SwitcherCLIProfileType.Claude, account: "b@x"),
        }, active: "a");
        var vm = SwitcherTestData.ViewModel(store);

        vm.SetActiveProfile(vm.Profiles.Single(p => p.Id == "b"));

        var rows = vm.CliSections.Single().Rows;
        Assert.False(rows.Single(r => r.Profile.Id == "a").IsActive);
        Assert.True(rows.Single(r => r.Profile.Id == "b").IsActive);
    }

    [Fact]
    public void RowsFor_ComputesSlotLabelsActiveAndCapabilityFlags()
    {
        var store = SwitcherTestData.Store(new[]
        {
            SwitcherTestData.Cli("a", SwitcherCLIProfileType.Claude, account: "a@x"),
            SwitcherTestData.Cli("b", SwitcherCLIProfileType.Claude, account: "b@x"),
        }, active: "a");
        var vm = SwitcherTestData.ViewModel(store);
        var group = vm.CliGroups.Single();

        var rows = vm.RowsFor(group);

        Assert.Equal("primary", rows[0].SlotLabel);
        Assert.Equal("reserve 1", rows[1].SlotLabel);
        Assert.True(rows[0].IsActive);
        Assert.False(rows[1].IsActive);

        // Primary cannot move up / cannot be "made primary"; reserve can.
        Assert.False(rows[0].CanMoveUp);
        Assert.True(rows[0].CanMoveDown);
        Assert.False(rows[0].CanSetPrimary);
        Assert.True(rows[1].CanMoveUp);
        Assert.True(rows[1].CanSetPrimary);
        Assert.True(rows[0].CanChangeAccount); // Claude supports reconnect
    }
}
