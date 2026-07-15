using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text.Json;
using OpenBurnBar.ComputerUse.Core.Audit;
using OpenBurnBar.ComputerUse.Core.Crypto;

namespace OpenBurnBar.App.Settings.ViewModels;

/// <summary>
/// Reads and exports the local Computer Use audit format without inventing a
/// successful result when the archive is missing or damaged.
///
/// The logger writes canonical manifest bytes, a parent-hash JSONL chain, and a
/// live head marker. Validation therefore hashes the manifest bytes exactly as
/// stored and always supplies the terminal head anchor to the portable verifier.
/// </summary>
public sealed class FileComputerUseAuditService : IComputerUseAuditService
{
    public const string RootEnvironmentVariable = "OPENBURNBAR_COMPUTER_USE_AUDIT_ROOT";
    private const long MaxManifestBytes = 256 * 1024;
    private const long MaxChainBytes = 32 * 1024 * 1024;
    private const long MaxArchiveBytes = 64 * 1024 * 1024;

    private readonly string _root;
    private readonly string _exportRoot;

    public FileComputerUseAuditService(string root, string? exportRoot = null)
    {
        if (string.IsNullOrWhiteSpace(root))
        {
            throw new ArgumentException("An audit root is required.", nameof(root));
        }

        _root = Path.GetFullPath(root);
        _exportRoot = Path.GetFullPath(exportRoot ?? Path.Combine(_root, "exports"));
    }

    public AuditActionResult ValidateChain(string sessionId)
    {
        if (!TryResolveSession(sessionId, out string sessionDirectory, out string normalizedId, out string error))
        {
            return AuditActionResult.Fail(error);
        }

        try
        {
            byte[] manifest = ReadBounded(Path.Combine(sessionDirectory, "manifest.json"), MaxManifestBytes);
            string chainPath = Path.Combine(sessionDirectory, "chain.jsonl");
            byte[] chain = File.Exists(chainPath)
                ? ReadBounded(chainPath, MaxChainBytes)
                : Array.Empty<byte>();
            string? expectedHead = ReadHeadHash(Path.Combine(sessionDirectory, "head.json"), normalizedId);
            if (expectedHead is null)
            {
                return AuditActionResult.Fail("Audit head marker is missing or invalid.");
            }

            string manifestHash = AuditHasher.Current.Hash(manifest);
            ComputerUseAuditSignedHead? signedHead = ReadSignedHead(
                Path.Combine(sessionDirectory, "signed_head.json"),
                normalizedId);
            if (signedHead is not null)
            {
                if (!string.Equals(signedHead.HeadHashHex, expectedHead, StringComparison.OrdinalIgnoreCase))
                {
                    return AuditActionResult.Fail("Signed audit head does not match the live head marker.");
                }

                AuditVerificationReport report = new ComputerUseAuditVerifier().Verify(
                    chain,
                    manifestHash,
                    signedHead);
                if (!report.IsFullyVerified)
                {
                    return AuditActionResult.Fail(
                        $"Signed audit chain is invalid ({report.FirstInvalidReason.ToWire()}).");
                }

                return AuditActionResult.Ok($"Audit chain verified ({report.EntryCount} entr{(report.EntryCount == 1 ? "y" : "ies")}, signed head).");
            }

            AuditChainValidationResult result = new ComputerUseAuditChain().Validate(
                chain,
                manifestHash,
                expectedHeadHashHex: expectedHead,
                requireExpectedHead: true);
            if (!result.IsValid)
            {
                return AuditActionResult.Fail(
                    $"Audit chain is invalid ({result.FirstInvalidReason.ToWire()}).");
            }

            return AuditActionResult.Ok($"Audit chain verified ({result.EntryCount} entr{(result.EntryCount == 1 ? "y" : "ies")}).");
        }
        catch (FileNotFoundException)
        {
            return AuditActionResult.Fail("Audit archive is incomplete: manifest, chain, and head are required.");
        }
        catch (InvalidDataException ex)
        {
            return AuditActionResult.Fail("Audit archive is invalid: " + ex.Message);
        }
        catch (JsonException)
        {
            return AuditActionResult.Fail("Audit archive contains malformed JSON.");
        }
        catch (UnauthorizedAccessException)
        {
            return AuditActionResult.Fail("Audit archive cannot be read due to file permissions.");
        }
        catch (IOException ex)
        {
            return AuditActionResult.Fail("Audit archive could not be read: " + ex.Message);
        }
    }

    public AuditActionResult ExportArchive(string sessionId, bool includeScreenshots)
    {
        if (!TryResolveSession(sessionId, out string sessionDirectory, out string normalizedId, out string error))
        {
            return AuditActionResult.Fail(error);
        }

        AuditActionResult validation = ValidateChain(normalizedId);
        if (!validation.Success)
        {
            return validation;
        }

        string archiveName = "cu-" + normalizedId + ".zip";
        string destination = Path.Combine(_exportRoot, archiveName);
        string temporary = destination + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            Directory.CreateDirectory(_exportRoot);
            long totalBytes = 0;
            using (var archive = ZipFile.Open(temporary, ZipArchiveMode.Create))
            {
                foreach (string relativePath in EnumerateExportFiles(sessionDirectory, includeScreenshots))
                {
                    string source = Path.Combine(sessionDirectory, relativePath);
                    long length = File.Exists(source) ? new FileInfo(source).Length : 0;
                    totalBytes = checked(totalBytes + length);
                    if (totalBytes > MaxArchiveBytes)
                    {
                        throw new InvalidDataException("Audit export exceeds the size limit.");
                    }

                    ZipArchiveEntry entry = archive.CreateEntry(relativePath, CompressionLevel.Fastest);
                    if (!File.Exists(source))
                    {
                        continue;
                    }

                    using Stream input = File.OpenRead(source);
                    using Stream output = entry.Open();
                    input.CopyTo(output);
                }
            }

            File.Move(temporary, destination, overwrite: true);
            return AuditActionResult.Ok("Audit archive exported to " + destination);
        }
        catch (InvalidDataException ex)
        {
            DeleteTemporary(temporary);
            return AuditActionResult.Fail("Audit export refused: " + ex.Message);
        }
        catch (UnauthorizedAccessException)
        {
            DeleteTemporary(temporary);
            return AuditActionResult.Fail("Audit export cannot write to the configured export directory.");
        }
        catch (IOException ex)
        {
            DeleteTemporary(temporary);
            return AuditActionResult.Fail("Audit export failed: " + ex.Message);
        }
    }

    public AuditActionResult Notarize(string sessionId) =>
        AuditActionResult.Fail("OpenTimestamps notarization requires the authenticated production account.");

    private bool TryResolveSession(
        string sessionId,
        out string sessionDirectory,
        out string normalizedId,
        out string error)
    {
        normalizedId = (sessionId ?? string.Empty).Trim();
        sessionDirectory = string.Empty;
        error = string.Empty;
        if (normalizedId.Length is < 1 or > 128
            || normalizedId.Any(ch => !(char.IsLetterOrDigit(ch) || ch is '-' or '_' or '.'))
            || normalizedId is "." or "..")
        {
            error = "Audit session id contains unsupported characters.";
            return false;
        }

        string root = _root.EndsWith(Path.DirectorySeparatorChar) ? _root : _root + Path.DirectorySeparatorChar;
        string candidate = Path.GetFullPath(Path.Combine(_root, normalizedId));
        if (!candidate.StartsWith(root, StringComparison.OrdinalIgnoreCase)
            || !Directory.Exists(candidate))
        {
            error = "No local audit archive exists for this session.";
            return false;
        }

        if (HasReparsePoint(new DirectoryInfo(candidate)))
        {
            error = "Audit archive path uses a reparse point and cannot be trusted.";
            return false;
        }

        sessionDirectory = candidate;
        return true;
    }

    private static byte[] ReadBounded(string path, long maxBytes)
    {
        var info = new FileInfo(path);
        if (!info.Exists)
        {
            throw new FileNotFoundException("Required audit file is missing.", path);
        }

        if (HasReparsePoint(info))
        {
            throw new InvalidDataException("Audit file uses a reparse point.");
        }

        if (info.Length < 0 || info.Length > maxBytes)
        {
            throw new InvalidDataException("Audit file exceeds the size limit.");
        }

        return File.ReadAllBytes(path);
    }

    private static string? ReadHeadHash(string path, string sessionId)
    {
        byte[] bytes = ReadBounded(path, 64 * 1024);
        using JsonDocument document = JsonDocument.Parse(bytes);
        JsonElement root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object
            || !root.TryGetProperty("sessionId", out JsonElement session)
            || session.ValueKind != JsonValueKind.String
            || !string.Equals(session.GetString(), sessionId, StringComparison.Ordinal)
            || !root.TryGetProperty("hashHex", out JsonElement hash)
            || hash.ValueKind != JsonValueKind.String)
        {
            return null;
        }

        string value = hash.GetString() ?? string.Empty;
        return value.Length == 64 && value.All(Uri.IsHexDigit) ? value.ToLowerInvariant() : null;
    }

    private static ComputerUseAuditSignedHead? ReadSignedHead(string path, string sessionId)
    {
        if (!File.Exists(path))
        {
            return null;
        }

        byte[] bytes = ReadBounded(path, 128 * 1024);
        using JsonDocument document = JsonDocument.Parse(bytes);
        JsonElement root = document.RootElement;
        string? fileSessionId = ReadString(root, "sessionId");
        string? headHash = ReadString(root, "headHashHex");
        string? signature = ReadString(root, "signatureEd25519Base64")
            ?? ReadString(root, "signatureEd25519");
        string? publicKey = ReadString(root, "signerPublicKeyEd25519Base64")
            ?? ReadString(root, "signerPublicKeyEd25519");
        if (root.ValueKind != JsonValueKind.Object
            || !string.Equals(fileSessionId, sessionId, StringComparison.Ordinal)
            || string.IsNullOrWhiteSpace(headHash)
            || headHash.Length != 64
            || !headHash.All(Uri.IsHexDigit)
            || string.IsNullOrWhiteSpace(signature)
            || string.IsNullOrWhiteSpace(publicKey)
            || !root.TryGetProperty("lastEntryIndex", out JsonElement indexElement)
            || !indexElement.TryGetInt32(out int lastEntryIndex))
        {
            throw new InvalidDataException("Signed audit head is incomplete.");
        }

        long closedAtMs = root.TryGetProperty("closedAtMs", out JsonElement closedAtElement)
            && closedAtElement.TryGetInt64(out long numericTimestamp)
            ? numericTimestamp
            : throw new InvalidDataException("Signed audit head timestamp is missing.");
        return new ComputerUseAuditSignedHead(
            sessionId,
            lastEntryIndex,
            headHash.ToLowerInvariant(),
            DateTimeOffset.FromUnixTimeMilliseconds(closedAtMs),
            signature,
            publicKey);
    }

    private static string? ReadString(JsonElement root, string name) =>
        root.TryGetProperty(name, out JsonElement element) && element.ValueKind == JsonValueKind.String
            ? element.GetString()
            : null;

    private static IEnumerable<string> EnumerateExportFiles(string sessionDirectory, bool includeScreenshots)
    {
        yield return "manifest.json";
        yield return "chain.jsonl";
        yield return "head.json";
        string signedHead = Path.Combine(sessionDirectory, "signed_head.json");
        if (File.Exists(signedHead))
        {
            yield return "signed_head.json";
        }

        string ots = Path.Combine(sessionDirectory, "chain.jsonl.ots");
        if (File.Exists(ots))
        {
            yield return "chain.jsonl.ots";
        }

        if (!includeScreenshots)
        {
            yield break;
        }

        string screenshotDirectory = Path.Combine(sessionDirectory, "screenshots");
        if (!Directory.Exists(screenshotDirectory))
        {
            yield break;
        }

        foreach (string path in Directory.EnumerateFiles(screenshotDirectory, "*.png", SearchOption.TopDirectoryOnly)
                     .OrderBy(path => path, StringComparer.OrdinalIgnoreCase))
        {
            if (HasReparsePoint(new FileInfo(path)))
            {
                throw new InvalidDataException("Screenshot uses a reparse point.");
            }

            yield return "screenshots/" + Path.GetFileName(path);
        }
    }

    private static bool HasReparsePoint(FileSystemInfo info) =>
        (info.Attributes & FileAttributes.ReparsePoint) != 0;

    private static void DeleteTemporary(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch (IOException)
        {
            // Best-effort cleanup; the original failure remains the result.
        }
    }
}
