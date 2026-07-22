using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using OpenBurnBar.App.Presentation.Switcher;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Switcher;

public sealed class SwitcherShellLaunchPlannerTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "obb-switcher-shell-tests", Guid.NewGuid().ToString("N"));

    public SwitcherShellLaunchPlannerTests() => Directory.CreateDirectory(_root);

    public void Dispose() => Directory.Delete(_root, recursive: true);

    [Theory]
    [InlineData(SwitcherCLIProfileType.Codex, "codex")]
    [InlineData(SwitcherCLIProfileType.Claude, "claude")]
    [InlineData(SwitcherCLIProfileType.CursorAgent, "cursor-agent")]
    [InlineData(SwitcherCLIProfileType.Gemini, "gemini")]
    public void UsesReviewedExecutableForCliType(SwitcherCLIProfileType cliType, string expected)
    {
        SwitcherShellLaunchPlan plan = SwitcherShellLaunchPlanner.Create(Profile(cliType));

        Assert.Equal(expected, plan.ExecutableName);
        Assert.Equal(cliType, plan.CliType);
    }

    [Fact]
    public void CombinesProfileAndForwardedArgumentsWithoutShellParsing()
    {
        var profile = Profile(SwitcherCLIProfileType.Claude, additionalArgs: new[] { "--verbose", "space value" });

        SwitcherShellLaunchPlan plan = SwitcherShellLaunchPlanner.Create(profile, new[] { "--print", "hello & goodbye" });

        Assert.Equal(new[] { "--verbose", "space value", "--print", "hello & goodbye" }, plan.Arguments);
    }

    [Fact]
    public void MapsProfileConfigDirectoryToCliSpecificVariables()
    {
        string config = Directory.CreateDirectory(Path.Combine(_root, "codex profile")).FullName;
        var profile = Profile(SwitcherCLIProfileType.Codex, configDirectory: config);

        SwitcherShellLaunchPlan plan = SwitcherShellLaunchPlanner.Create(profile);

        Assert.Equal(config, plan.RequiredEnvironment["CODEX_HOME"]);
        Assert.Equal(config, plan.RequiredEnvironment["CODEX_CONFIG_PATH"]);
        Assert.DoesNotContain("CLAUDE_CONFIG_DIR", plan.RequiredEnvironment.Keys);
    }

    [Fact]
    public void PassesOnlyExplicitAllowlistedAmbientKeys()
    {
        var profile = Profile(SwitcherCLIProfileType.Claude, envKeys: new[] { "TERM", "EDITOR" });
        var source = new Dictionary<string, string?>
        {
            ["TERM"] = "xterm-256color",
            ["EDITOR"] = "code --wait",
            ["OPENAI_API_KEY"] = "must-not-pass",
        };

        SwitcherShellLaunchPlan plan = SwitcherShellLaunchPlanner.Create(profile, sourceEnvironment: source);

        Assert.Equal("xterm-256color", plan.RequiredEnvironment["TERM"]);
        Assert.Equal("code --wait", plan.RequiredEnvironment["EDITOR"]);
        Assert.DoesNotContain("OPENAI_API_KEY", plan.RequiredEnvironment.Keys);
    }

    [Fact]
    public void RejectsUnreviewedEnvironmentKey()
    {
        var profile = Profile(SwitcherCLIProfileType.Codex, envKeys: new[] { "OPENAI_API_KEY" });

        InvalidOperationException error = Assert.Throws<InvalidOperationException>(() =>
            SwitcherShellLaunchPlanner.Create(
                profile,
                sourceEnvironment: new Dictionary<string, string?> { ["OPENAI_API_KEY"] = "secret" }));

        Assert.Contains("not allowlisted", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void RejectsDisabledAndBrowserProfiles()
    {
        Assert.Throws<InvalidOperationException>(() =>
            SwitcherShellLaunchPlanner.Create(Profile(SwitcherCLIProfileType.Codex, disabled: true)));
        Assert.Throws<InvalidOperationException>(() =>
            SwitcherShellLaunchPlanner.Create(new SwitcherProfileRecord(
                "browser",
                SwitcherProfileTargetKind.Browser,
                0,
                BrowserType: SwitcherBrowserProfileType.Chrome,
                BrowserMetadata: new SwitcherBrowserProfileMetadata("Default"))));
    }

    [Fact]
    public void RejectsMissingProfileAndMissingDirectories()
    {
        var store = new InMemorySwitcherProfileStore();
        Assert.Throws<InvalidOperationException>(() => SwitcherShellLaunchPlanner.CreateForProfile(store, "missing"));
        Assert.Throws<InvalidOperationException>(() => SwitcherShellLaunchPlanner.Create(
            Profile(SwitcherCLIProfileType.Codex, workingDirectory: Path.Combine(_root, "missing"))));
    }

    [Fact]
    public void RejectsControlCharactersAndExcessiveArgumentCount()
    {
        Assert.Throws<InvalidOperationException>(() =>
            SwitcherShellLaunchPlanner.Create(Profile(SwitcherCLIProfileType.Codex), new[] { "bad\0arg" }));
        Assert.Throws<InvalidOperationException>(() =>
            SwitcherShellLaunchPlanner.Create(
                Profile(SwitcherCLIProfileType.Codex),
                Enumerable.Range(0, 65).Select(index => index.ToString()).ToArray()));
    }

    private SwitcherProfileRecord Profile(
        SwitcherCLIProfileType cliType,
        IReadOnlyList<string>? additionalArgs = null,
        IReadOnlyList<string>? envKeys = null,
        string? workingDirectory = null,
        string? configDirectory = null,
        bool disabled = false) =>
        new(
            Id: $"{cliType.RawValue()}-profile",
            TargetKind: SwitcherProfileTargetKind.Cli,
            SortKey: 0,
            CliType: cliType,
            CliMetadata: new SwitcherCLIProfileMetadata(
                WorkingDirectory: workingDirectory,
                AdditionalArgs: additionalArgs,
                EnvKeysToPass: envKeys,
                ConfigDirectory: configDirectory,
                IsDisabled: disabled));
}
