using System;
using System.IO;
using System.Threading.Tasks;
using OpenBurnBar.App.UsageRuntime;
using Xunit;

namespace OpenBurnBar.App.UsageRuntime.Tests;

public sealed class NativeUsageEngineIntegrationTests
{
    [Fact]
    public async Task ScanAsync_RealCAbi_ParsesProviderLogsInProcess()
    {
        string? enginePath = Environment.GetEnvironmentVariable("OPENBURNBAR_CORE_CABI_PATH");
        bool required = string.Equals(
            Environment.GetEnvironmentVariable("OPENBURNBAR_REQUIRE_NATIVE_ENGINE_INTEGRATION"),
            "1",
            StringComparison.Ordinal);
        if (string.IsNullOrWhiteSpace(enginePath))
        {
            Assert.False(required, "OPENBURNBAR_CORE_CABI_PATH is required by this integration run.");
            return;
        }

        Assert.True(File.Exists(enginePath), $"Native engine does not exist: {enginePath}");
        string root = Path.Combine(
            Path.GetTempPath(),
            "obb-native-usage-" + Guid.NewGuid().ToString("N"));
        try
        {
            string claude = Path.Combine(root, ".claude", "projects", "-C-src-BurnBar");
            string cursor = Path.Combine(root, ".cursor-agent", "sessions");
            Directory.CreateDirectory(claude);
            Directory.CreateDirectory(cursor);
            File.Copy(
                Path.Combine(AppContext.BaseDirectory, "Fixtures", "pc-claude-basic-session.jsonl"),
                Path.Combine(claude, "claude-basic-session.jsonl"));
            await File.WriteAllTextAsync(
                Path.Combine(cursor, "cursor-basic.jsonl"),
                """
                {"role":"user","content":"Inspect the Windows usage runtime","timestamp":"2026-07-10T12:00:00Z"}
                {"role":"assistant","content":"The native bridge is active.","timestamp":"2026-07-10T12:00:01Z"}
                """);

            using var engine = new CAbiUsageEngine(() => enginePath);
            UsageEngineScanResponse response = await engine.ScanAsync(new UsageEngineScanRequest
            {
                SupportDirectory = Path.Combine(root, "support"),
                HomeDirectory = root,
                ClaudeProjectsDirectory = Path.Combine(root, ".claude", "projects"),
                CodexHomeDirectory = root,
                CursorSessionsDirectory = cursor,
                FactorySessionsDirectory = Path.Combine(root, ".factory", "sessions"),
                HermesHomeDirectory = Path.Combine(root, ".hermes"),
                IncludeConversationBodies = true,
            });

            Assert.True(response.Ok, response.Error);
            Assert.Contains(response.Providers, item =>
                item.Provider == "Claude Code" && item.Status == UsageProviderScanStatus.Succeeded);
            Assert.Contains(response.Providers, item =>
                item.Provider == "Cursor Agent" && item.Status == UsageProviderScanStatus.Succeeded);
            Assert.Contains(response.Usages, item => item.Provider == "Claude Code");
            Assert.Contains(response.Usages, item => item.Provider == "Cursor Agent");
            Assert.NotEmpty(response.Conversations);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }
}
