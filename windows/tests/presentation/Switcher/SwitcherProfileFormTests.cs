using System;
using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Presentation.Switcher;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Switcher;

/// <summary>
/// Pins the form validation + record construction ported from validateForm /
/// buildProfileRecord / saveProfileAsync / editProfile.
/// </summary>
public sealed class SwitcherProfileFormTests
{
    [Fact]
    public void Validate_Browser_RequiresProfileIdentifier()
    {
        var form = new SwitcherProfileForm
        {
            TargetKind = SwitcherProfileTargetKind.Browser,
            ProfileIdentifier = string.Empty,
        };

        var result = form.Validate(Array.Empty<string>());

        Assert.False(result.IsValid);
        Assert.Equal("Profile identifier is required", result.ValidationError);
        Assert.Equal("Profile identifier is required", form.ValidationError);
    }

    [Fact]
    public void Validate_Cli_DoesNotRequireProfileIdentifier()
    {
        var form = new SwitcherProfileForm { TargetKind = SwitcherProfileTargetKind.Cli };
        Assert.True(form.Validate(Array.Empty<string>()).IsValid);
    }

    [Fact]
    public void Validate_DuplicateName_NormalizedComparison()
    {
        var form = new SwitcherProfileForm
        {
            TargetKind = SwitcherProfileTargetKind.Cli,
            Name = "  Work   Account ",
        };

        var result = form.Validate(new[] { "work account" });

        Assert.False(result.IsValid);
        Assert.Equal("A profile with this name already exists", result.DuplicateError);
    }

    [Fact]
    public void Validate_EmptyName_SkipsDuplicateCheck()
    {
        var form = new SwitcherProfileForm { TargetKind = SwitcherProfileTargetKind.Cli, Name = string.Empty };
        Assert.True(form.Validate(new[] { "anything" }).IsValid);
    }

    [Fact]
    public void BuildNewRecord_Cli_ParsesArgsAndEnvKeys_EmptyBecomesNull()
    {
        var form = new SwitcherProfileForm
        {
            TargetKind = SwitcherProfileTargetKind.Cli,
            CliType = SwitcherCLIProfileType.Codex,
            Name = string.Empty,
            WorkingDirectory = string.Empty,
            AdditionalArgs = "--verbose   --no-color",
            EnvKeys = "HOME, PATH ,TERM",
        };

        var record = form.BuildNewRecord("id-1", SwitcherTestData.Now);

        Assert.Equal(SwitcherProfileTargetKind.Cli, record.TargetKind);
        Assert.Equal(SwitcherCLIProfileType.Codex, record.CliType);
        Assert.Null(record.CliMetadata!.WorkingDirectory);
        Assert.Null(record.CliMetadata.DisplayLabel);
        Assert.Equal(new[] { "--verbose", "--no-color" }, record.CliMetadata.AdditionalArgs);
        Assert.Equal(new[] { "HOME", "PATH", "TERM" }, record.CliMetadata.EnvKeysToPass);
    }

    [Fact]
    public void BuildNewRecord_Browser_UsesIdentifierAndLabel()
    {
        var form = new SwitcherProfileForm
        {
            TargetKind = SwitcherProfileTargetKind.Browser,
            BrowserType = SwitcherBrowserProfileType.Chrome,
            ProfileIdentifier = "Profile 1",
            Name = "Personal",
        };

        var record = form.BuildNewRecord("id-1", SwitcherTestData.Now);

        Assert.Equal(SwitcherBrowserProfileType.Chrome, record.BrowserType);
        Assert.Equal("Profile 1", record.BrowserMetadata!.ProfileIdentifier);
        Assert.Equal("Personal", record.BrowserMetadata.DisplayLabel);
        Assert.Equal("Personal", record.DisplayName);
    }

    [Fact]
    public void BuildUpdatedRecord_Cli_PreservesUntouchedMetadata()
    {
        var original = new SwitcherProfileRecord(
            Id: "keep-id",
            TargetKind: SwitcherProfileTargetKind.Cli,
            SortKey: 3,
            CliType: SwitcherCLIProfileType.Claude,
            CliMetadata: new SwitcherCLIProfileMetadata(
                DisplayLabel: "Old",
                ConfigDirectory: "/cfg/claude-a",
                AccountDescription: "Alice • alice@x",
                ProviderId: "claude-code",
                RuntimeAccountId: "rt-1",
                SubscriptionTierId: "pro",
                LinkedHarnessIds: new[] { "codex" },
                IsDisabled: true),
            CreatedAt: SwitcherTestData.Now.AddDays(-2));

        var form = SwitcherProfileForm.LoadFrom(original);
        form.Name = "Renamed";
        form.AdditionalArgs = "--x";

        var updated = form.BuildUpdatedRecord(original, SwitcherTestData.Now);

        Assert.Equal("keep-id", updated.Id);
        Assert.Equal(3, updated.SortKey);
        Assert.Equal("Renamed", updated.CliMetadata!.DisplayLabel);
        Assert.Equal(new[] { "--x" }, updated.CliMetadata.AdditionalArgs);
        // Preserved fields:
        Assert.Equal("/cfg/claude-a", updated.CliMetadata.ConfigDirectory);
        Assert.Equal("Alice • alice@x", updated.CliMetadata.AccountDescription);
        Assert.Equal("claude-code", updated.CliMetadata.ProviderId);
        Assert.Equal("rt-1", updated.CliMetadata.RuntimeAccountId);
        Assert.Equal("pro", updated.CliMetadata.SubscriptionTierId);
        Assert.Equal(new[] { "codex" }, updated.CliMetadata.LinkedHarnessIds);
        Assert.True(updated.CliMetadata.IsDisabled);
        Assert.Equal(original.CreatedAt, updated.CreatedAt);
    }

    [Fact]
    public void BuildUpdatedRecord_Browser_PreservesEmailProviderServicesAndDisabled()
    {
        var original = SwitcherTestData.Browser(
            "b1", SwitcherBrowserProfileType.Chrome,
            profileIdentifier: "Profile 2",
            email: "me@gmail.com",
            providerIdentifier: "google",
            disabled: true,
            services: new[] { new BrowserServiceIdentity(BrowserServiceProvider.OpenAI, "acct") });

        var form = SwitcherProfileForm.LoadFrom(original);
        form.Name = "Work Chrome";
        form.ProfileIdentifier = "Profile 9";

        var updated = form.BuildUpdatedRecord(original, SwitcherTestData.Now);

        Assert.Equal("Profile 9", updated.BrowserMetadata!.ProfileIdentifier);
        Assert.Equal("Work Chrome", updated.BrowserMetadata.DisplayLabel);
        Assert.Equal("me@gmail.com", updated.BrowserMetadata.AccountEmail);
        Assert.Equal("google", updated.BrowserMetadata.ProviderIdentifier);
        Assert.True(updated.BrowserMetadata.IsDisabled);
        Assert.Single(updated.BrowserMetadata.ServiceIdentities);
    }

    [Fact]
    public void LoadFrom_RoundTripsArgsAndEnvKeysToEditableStrings()
    {
        var original = SwitcherTestData.Cli(
            "c1", SwitcherCLIProfileType.Codex,
            label: "Codex Work",
            args: new[] { "--verbose", "--no-color" },
            env: new[] { "HOME", "PATH" },
            workingDir: "/work");

        var form = SwitcherProfileForm.LoadFrom(original);

        Assert.Equal("Codex Work", form.Name);
        Assert.Equal(SwitcherProfileTargetKind.Cli, form.TargetKind);
        Assert.Equal(SwitcherCLIProfileType.Codex, form.CliType);
        Assert.Equal("/work", form.WorkingDirectory);
        Assert.Equal("--verbose --no-color", form.AdditionalArgs);
        Assert.Equal("HOME, PATH", form.EnvKeys);
    }

    [Fact]
    public void ParseArgs_And_ParseEnvKeys_EdgeCases()
    {
        Assert.Empty(SwitcherProfileForm.ParseArgs(string.Empty));
        Assert.Empty(SwitcherProfileForm.ParseArgs("   "));
        Assert.Equal(new[] { "a", "b" }, SwitcherProfileForm.ParseArgs("a   b"));

        Assert.Empty(SwitcherProfileForm.ParseEnvKeys(string.Empty));
        Assert.Equal(new[] { "A", "B" }, SwitcherProfileForm.ParseEnvKeys(" A , B "));
    }
}
