using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using OpenBurnBar.App.Quota.Acquisition;
using Xunit;

namespace OpenBurnBar.App.Quota.Acquisition.Tests;

/// <summary>
/// Mechanism 1 hook installer — parity with ClaudeQuotaBridgeManager: settings.json
/// statusLine routing, original-statusline preservation + chained command spec in
/// the metadata sidecar, wrapper-pair contract, uninstall restore.
/// </summary>
public sealed class ClaudeStatuslineHookInstallerTests : IDisposable
{
    private readonly string _dir = AcquisitionTestSupport.CreateTempDirectory();

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    private ClaudeStatuslineHookPaths Paths => new(
        ClaudeSettingsPath: Path.Combine(_dir, ".claude", "settings.json"),
        WrapperCmdPath: Path.Combine(_dir, "OpenBurnBar", "claude_statusline_bridge.cmd"),
        WrapperPs1Path: Path.Combine(_dir, "OpenBurnBar", "claude_statusline_bridge.ps1"),
        SnapshotPath: Path.Combine(_dir, "OpenBurnBar", "claude_statusline_snapshot.json"),
        MetadataPath: Path.Combine(_dir, "OpenBurnBar", "claude_statusline_bridge_metadata.json"));

    private ClaudeStatuslineHookInstaller Installer() =>
        new(Paths, () => DateTimeOffset.FromUnixTimeSeconds(1783036800));

    [Fact]
    public void Install_FreshMachine_RoutesStatusLineThroughWrapper()
    {
        var installer = Installer();

        installer.Install();

        JsonObject settings = ReadSettings();
        Assert.Equal("command", settings["statusLine"]?["type"]?.GetValue<string>());
        Assert.Equal(installer.BridgeCommand, settings["statusLine"]?["command"]?.GetValue<string>());
        Assert.True(File.Exists(Paths.WrapperCmdPath));
        Assert.True(File.Exists(Paths.WrapperPs1Path));
        Assert.True(installer.IsInstalled());

        // Fresh install: nothing to chain — originalStatusLine records null.
        JsonObject metadata = ReadMetadata();
        Assert.Equal(JsonValueKind.Null, ValueKind(metadata["originalStatusLine"]));
        Assert.Equal(JsonValueKind.Null, ValueKind(metadata["originalCommandSpec"]));
        Assert.Equal(Paths.WrapperCmdPath, metadata["wrapperPath"]?.GetValue<string>());
    }

    [Fact]
    public void Install_PreservesExistingStatuslineAndCommandSpec()
    {
        WriteSettings("""{"statusLine":{"type":"command","command":"bun x ccusage statusline"},"model":"opus"}""");

        Installer().Install();

        JsonObject metadata = ReadMetadata();
        Assert.Equal("bun x ccusage statusline",
            metadata["originalStatusLine"]?["command"]?.GetValue<string>());
        Assert.Equal("bun", metadata["originalCommandSpec"]?["executable"]?.GetValue<string>());
        var arguments = metadata["originalCommandSpec"]?["arguments"]?.AsArray();
        Assert.NotNull(arguments);
        Assert.Equal(new[] { "x", "ccusage", "statusline" },
            new[] { arguments![0]!.GetValue<string>(), arguments[1]!.GetValue<string>(), arguments[2]!.GetValue<string>() });

        // Unrelated settings keys survive the edit.
        Assert.Equal("opus", ReadSettings()["model"]?.GetValue<string>());
    }

    [Fact]
    public void Install_Twice_NeverRecordsTheBridgeAsOriginal()
    {
        WriteSettings("""{"statusLine":{"type":"command","command":"my-statusline.exe"}}""");
        var installer = Installer();

        installer.Install();
        installer.Install();

        Assert.Equal("my-statusline.exe",
            ReadMetadata()["originalStatusLine"]?["command"]?.GetValue<string>());
    }

    [Fact]
    public void Install_UnsafeOriginalCommand_PreservesRawButRefusesSpec()
    {
        // Swift shellSplit rejects metacharacters — the raw statusLine is still
        // preserved for restore, but nothing is chained.
        WriteSettings("""{"statusLine":{"type":"command","command":"foo | bar"}}""");

        Installer().Install();

        JsonObject metadata = ReadMetadata();
        Assert.Equal("foo | bar", metadata["originalStatusLine"]?["command"]?.GetValue<string>());
        Assert.Equal(JsonValueKind.Null, ValueKind(metadata["originalCommandSpec"]));
    }

    [Fact]
    public void WrapperScripts_CarryTheTeeAndChainContract()
    {
        Installer().Install();

        var cmd = File.ReadAllText(Paths.WrapperCmdPath);
        Assert.Contains(Paths.WrapperPs1Path, cmd, StringComparison.Ordinal);
        Assert.Contains("powershell.exe -NoProfile", cmd, StringComparison.Ordinal);

        var ps1 = File.ReadAllText(Paths.WrapperPs1Path);
        Assert.Contains(Paths.SnapshotPath, ps1, StringComparison.Ordinal);
        Assert.Contains(Paths.MetadataPath, ps1, StringComparison.Ordinal);
        // stdin tee → snapshot, then replay into the original command.
        Assert.Contains("[Console]::In.ReadToEnd()", ps1, StringComparison.Ordinal);
        Assert.Contains("WriteAllText($snapshotPath, $payload)", ps1, StringComparison.Ordinal);
        Assert.Contains("originalCommandSpec", ps1, StringComparison.Ordinal);
        Assert.Contains("RedirectStandardInput", ps1, StringComparison.Ordinal);
        // Self-invocation guard (never chain the wrapper into itself).
        Assert.Contains("$spec.executable -ne $wrapper", ps1, StringComparison.Ordinal);
    }

    [Fact]
    public void Uninstall_RestoresTheOriginalStatusLine()
    {
        WriteSettings("""{"statusLine":{"type":"command","command":"my-statusline.exe","padding":0}}""");
        var installer = Installer();
        installer.Install();

        installer.Uninstall();

        JsonObject settings = ReadSettings();
        Assert.Equal("my-statusline.exe", settings["statusLine"]?["command"]?.GetValue<string>());
        Assert.Equal(0, settings["statusLine"]?["padding"]?.GetValue<int>());
        Assert.False(File.Exists(Paths.WrapperCmdPath));
        Assert.False(File.Exists(Paths.WrapperPs1Path));
        Assert.False(File.Exists(Paths.MetadataPath));
        Assert.False(installer.IsInstalled());
    }

    [Fact]
    public void Uninstall_WhenThereWasNoOriginal_RemovesTheKey()
    {
        var installer = Installer();
        installer.Install();

        installer.Uninstall();

        Assert.False(ReadSettings().ContainsKey("statusLine"));
    }

    [Fact]
    public void CommandSpec_SplitsQuotedSegments()
    {
        var (executable, arguments) =
            ClaudeStatuslineHookInstaller.CommandSpec("\"C:\\Program Files\\status.exe\" --fast 'two words'");

        Assert.Equal("C:\\Program Files\\status.exe", executable);
        Assert.Equal(new[] { "--fast", "two words" }, arguments);
    }

    private void WriteSettings(string json)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Paths.ClaudeSettingsPath)!);
        File.WriteAllText(Paths.ClaudeSettingsPath, json);
    }

    private JsonObject ReadSettings() =>
        (JsonObject)JsonNode.Parse(File.ReadAllText(Paths.ClaudeSettingsPath))!;

    private JsonObject ReadMetadata() =>
        (JsonObject)JsonNode.Parse(File.ReadAllText(Paths.MetadataPath))!;

    private static JsonValueKind ValueKind(JsonNode? node) =>
        node?.GetValueKind() ?? JsonValueKind.Null;
}
