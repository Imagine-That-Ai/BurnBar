using System;
using System.IO;
using System.IO.Compression;
using System.Text.Json;
using OpenBurnBar.ComputerUse.Core.Crypto;

namespace OpenBurnBar.ComputerUse.Core.Audit;

/// <summary>Result of validating or exporting one on-disk Computer Use audit session.</summary>
public sealed record AuditArchiveResult(
    bool Success,
    string Message,
    int EntryCount = 0,
    string? HeadHashHex = null,
    string? ArtifactPath = null);

/// <summary>Validates and exports file-backed audit sessions without platform dependencies.</summary>
public sealed class ComputerUseAuditArchive
{
    private readonly string _sessionsDirectory;
    private readonly string _exportsDirectory;

    public ComputerUseAuditArchive(string sessionsDirectory, string? exportsDirectory = null)
    {
        _sessionsDirectory = Path.GetFullPath(sessionsDirectory ?? throw new ArgumentNullException(nameof(sessionsDirectory)));
        _exportsDirectory = Path.GetFullPath(exportsDirectory ?? Path.Combine(_sessionsDirectory, "exports"));
    }

    public AuditArchiveResult Validate(string sessionId)
    {
        if (!TryResolveSession(sessionId, out string sessionDirectory, out string error))
        {
            return new AuditArchiveResult(false, error);
        }

        string manifestPath = Path.Combine(sessionDirectory, "manifest.json");
        string headPath = Path.Combine(sessionDirectory, "head.json");
        string chainPath = Path.Combine(sessionDirectory, "chain.jsonl");
        if (!File.Exists(manifestPath) || !File.Exists(headPath))
        {
            return new AuditArchiveResult(false, "Audit session is missing manifest.json or head.json.");
        }

        try
        {
            byte[] manifest = File.ReadAllBytes(manifestPath);
            byte[] chain = File.Exists(chainPath) ? File.ReadAllBytes(chainPath) : Array.Empty<byte>();
            using JsonDocument head = JsonDocument.Parse(File.ReadAllBytes(headPath));
            JsonElement root = head.RootElement;
            string? storedSessionId = ReadString(root, "sessionId");
            string? expectedHead = ReadString(root, "hashHex");
            int expectedCount = ReadInt(root, "index", -1);
            if (!string.Equals(storedSessionId, sessionId, StringComparison.Ordinal)
                || string.IsNullOrWhiteSpace(expectedHead)
                || expectedCount < 0)
            {
                return new AuditArchiveResult(false, "Audit head metadata is invalid.");
            }

            var validator = new ComputerUseAuditChain();
            string manifestHash = AuditHasher.Current.Hash(manifest);
            AuditChainValidationResult result = validator.Validate(
                chain,
                manifestHash,
                expectedHeadHashHex: expectedHead,
                requireExpectedHead: true);
            if (!result.IsValid)
            {
                return new AuditArchiveResult(
                    false,
                    $"Audit chain verification failed: {result.FirstInvalidReason}.",
                    result.EntryCount,
                    result.HeadHashHex);
            }

            if (result.EntryCount != expectedCount)
            {
                return new AuditArchiveResult(
                    false,
                    $"Audit head entry count mismatch: expected {expectedCount}, verified {result.EntryCount}.",
                    result.EntryCount,
                    result.HeadHashHex);
            }

            return new AuditArchiveResult(
                true,
                $"Audit chain verified ({result.EntryCount} entries).",
                result.EntryCount,
                result.HeadHashHex);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            return new AuditArchiveResult(false, $"Audit chain could not be read: {ex.Message}");
        }
    }

    public AuditArchiveResult Export(string sessionId, bool includeScreenshots)
    {
        AuditArchiveResult validation = Validate(sessionId);
        if (!validation.Success)
        {
            return validation;
        }

        if (!TryResolveSession(sessionId, out string sessionDirectory, out string error))
        {
            return new AuditArchiveResult(false, error);
        }

        try
        {
            Directory.CreateDirectory(_exportsDirectory);
            string archivePath = Path.Combine(
                _exportsDirectory,
                $"{sessionId}-{DateTimeOffset.UtcNow:yyyyMMddTHHmmssfffZ}.zip");
            using FileStream stream = new(archivePath, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None);
            using var archive = new ZipArchive(stream, ZipArchiveMode.Create);
            foreach (string file in Directory.EnumerateFiles(sessionDirectory, "*", SearchOption.AllDirectories))
            {
                string relative = Path.GetRelativePath(sessionDirectory, file);
                if (!includeScreenshots && IsScreenshotPath(relative))
                {
                    continue;
                }

                archive.CreateEntryFromFile(file, relative.Replace('\\', '/'), CompressionLevel.Optimal);
            }

            return validation with
            {
                Message = includeScreenshots
                    ? "Audit archive exported with private screenshots."
                    : "Audit archive exported without private screenshots.",
                ArtifactPath = archivePath,
            };
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return new AuditArchiveResult(false, $"Audit archive export failed: {ex.Message}");
        }
    }

    private bool TryResolveSession(string sessionId, out string sessionDirectory, out string error)
    {
        string trimmed = sessionId?.Trim() ?? string.Empty;
        if (trimmed.Length == 0
            || !string.Equals(trimmed, Path.GetFileName(trimmed), StringComparison.Ordinal)
            || trimmed.IndexOfAny(new[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar }) >= 0)
        {
            sessionDirectory = string.Empty;
            error = "Audit session id is invalid.";
            return false;
        }

        sessionDirectory = Path.GetFullPath(Path.Combine(_sessionsDirectory, trimmed));
        string expectedPrefix = _sessionsDirectory.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!sessionDirectory.StartsWith(expectedPrefix, StringComparison.OrdinalIgnoreCase)
            || !Directory.Exists(sessionDirectory))
        {
            error = "Audit session was not found.";
            return false;
        }

        error = string.Empty;
        return true;
    }

    private static bool IsScreenshotPath(string relativePath) =>
        relativePath.StartsWith($"screenshots{Path.DirectorySeparatorChar}", StringComparison.OrdinalIgnoreCase)
        || relativePath.StartsWith("screenshots/", StringComparison.OrdinalIgnoreCase);

    private static string? ReadString(JsonElement root, string name) =>
        root.TryGetProperty(name, out JsonElement value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static int ReadInt(JsonElement root, string name, int fallback) =>
        root.TryGetProperty(name, out JsonElement value) && value.TryGetInt32(out int parsed)
            ? parsed
            : fallback;
}
