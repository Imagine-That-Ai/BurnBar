using System;
using System.IO;
using System.IO.Compression;
using System.Linq;
using OpenBurnBar.App.Settings.ViewModels;
using OpenBurnBar.ComputerUse.Core.Audit;
using OpenBurnBar.ComputerUse.Core.Gate;
using Xunit;

namespace OpenBurnBar.App.Settings.ViewModels.Tests;

public sealed class ComputerUseFileAuditServiceTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "obb-cu-audit-" + Guid.NewGuid().ToString("N"));

    [Fact]
    public void ValidateChainRequiresTheTerminalHeadAnchor()
    {
        ComputerUseAuditLogger logger = CreateSession("session-1");
        var service = new FileComputerUseAuditService(_root);

        AuditActionResult result = service.ValidateChain(logger.SessionId);

        Assert.True(result.Success, result.Message);
        Assert.Contains("0 entries", result.Message, StringComparison.Ordinal);
        File.Delete(Path.Combine(logger.Directory, "head.json"));
        Assert.False(service.ValidateChain(logger.SessionId).Success);
    }

    [Fact]
    public void TamperedChainFailsClosedBeforeExport()
    {
        ComputerUseAuditLogger logger = CreateSession("session-2");
        File.WriteAllText(Path.Combine(logger.Directory, "chain.jsonl"), "{\"tampered\":true}\n");
        var service = new FileComputerUseAuditService(_root);

        AuditActionResult result = service.ExportArchive(logger.SessionId, includeScreenshots: false);

        Assert.False(result.Success);
        Assert.Contains("invalid", result.Message, StringComparison.OrdinalIgnoreCase);
        Assert.Empty(Directory.Exists(Path.Combine(_root, "exports"))
            ? Directory.EnumerateFiles(Path.Combine(_root, "exports"))
            : Array.Empty<string>());
    }

    [Fact]
    public void ExportIncludesOnlyRequestedScreenshotPayloads()
    {
        ComputerUseAuditLogger logger = CreateSession("session-3");
        string screenshots = Path.Combine(logger.Directory, "screenshots");
        File.WriteAllBytes(Path.Combine(screenshots, "before.png"), new byte[] { 1, 2, 3 });
        var service = new FileComputerUseAuditService(_root);

        AuditActionResult result = service.ExportArchive(logger.SessionId, includeScreenshots: true);

        Assert.True(result.Success, result.Message);
        string archivePath = result.Message["Audit archive exported to ".Length..];
        using ZipArchive archive = ZipFile.OpenRead(archivePath);
        string[] names = archive.Entries.Select(entry => entry.FullName).ToArray();
        Assert.Contains("manifest.json", names);
        Assert.Contains("chain.jsonl", names);
        Assert.Contains("head.json", names);
        Assert.Contains("screenshots/before.png", names);
    }

    [Fact]
    public void SessionIdIsPathConfined()
    {
        var service = new FileComputerUseAuditService(_root);

        AuditActionResult result = service.ValidateChain("../other");

        Assert.False(result.Success);
        Assert.Contains("unsupported", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    private ComputerUseAuditLogger CreateSession(string sessionId)
    {
        var logger = new ComputerUseAuditLogger(sessionId, _root, "1.0.29");
        logger.BeginSession(new ComputerUseSessionManifest(
            sessionId,
            ComputerUseMode.Browser,
            ComputerUseTrustMode.Manual,
            DateTimeOffset.UnixEpoch,
            "user",
            "openburnbar",
            actionCap: 10,
            sessionTimeoutSeconds: 60));
        return logger;
    }

    public void Dispose()
    {
        if (Directory.Exists(_root))
        {
            Directory.Delete(_root, recursive: true);
        }
    }
}
