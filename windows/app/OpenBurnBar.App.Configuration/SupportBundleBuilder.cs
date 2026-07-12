using System.IO.Compression;
using System.Text;

namespace OpenBurnBar.App.Configuration;

public sealed record SupportBundleOptions(
    long MaxFileBytes = 256 * 1024,
    string RootEntryName = "openburnbar-support");

public sealed record SupportBundleResult(
    string BundlePath,
    IReadOnlyList<string> IncludedArtifacts,
    IReadOnlyList<string> SkippedArtifacts);

public static class SupportBundleBuilder
{
    private static readonly HashSet<string> TextExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".csv",
        ".json",
        ".jsonl",
        ".log",
        ".md",
        ".ps1",
        ".txt",
        ".xml",
        ".yaml",
        ".yml",
    };

    private static readonly HashSet<string> SensitiveExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".db",
        ".sqlite",
        ".sqlite3",
    };

    public static SupportBundleResult Create(
        string bundlePath,
        IEnumerable<string> sourcePaths,
        SupportBundleOptions? options = null)
    {
        options ??= new SupportBundleOptions();
        if (string.IsNullOrWhiteSpace(bundlePath))
        {
            throw new ArgumentException("Bundle path is required.", nameof(bundlePath));
        }

        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(bundlePath))!);
        if (File.Exists(bundlePath))
        {
            File.Delete(bundlePath);
        }

        var included = new List<string>();
        var skipped = new List<string>();
        using var archive = ZipFile.Open(bundlePath, ZipArchiveMode.Create);

        foreach (string path in Expand(sourcePaths))
        {
            string fullPath = Path.GetFullPath(path);
            string artifactName = EntryName(options.RootEntryName, fullPath);
            if (ShouldSkip(fullPath, out string reason))
            {
                skipped.Add($"{artifactName}: {reason}");
                continue;
            }

            try
            {
                string text = ReadBoundedText(fullPath, options.MaxFileBytes);
                text = SecretRedactor.Shared.Redact(text);
                ZipArchiveEntry entry = archive.CreateEntry(artifactName, CompressionLevel.Optimal);
                using Stream stream = entry.Open();
                using var writer = new StreamWriter(stream, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
                writer.Write(text);
                included.Add(artifactName);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or DecoderFallbackException)
            {
                skipped.Add($"{artifactName}: unreadable ({ex.GetType().Name})");
            }
        }

        return new SupportBundleResult(bundlePath, included, skipped);
    }

    private static IEnumerable<string> Expand(IEnumerable<string> sourcePaths)
    {
        foreach (string sourcePath in sourcePaths.Where(path => !string.IsNullOrWhiteSpace(path)))
        {
            string fullPath = Path.GetFullPath(sourcePath);
            if (File.Exists(fullPath))
            {
                yield return fullPath;
                continue;
            }

            if (!Directory.Exists(fullPath))
            {
                continue;
            }

            foreach (string file in Directory.EnumerateFiles(fullPath, "*", SearchOption.AllDirectories)
                         .OrderBy(path => path, StringComparer.OrdinalIgnoreCase))
            {
                yield return file;
            }
        }
    }

    private static bool ShouldSkip(string path, out string reason)
    {
        string extension = Path.GetExtension(path);
        if (SensitiveExtensions.Contains(extension))
        {
            reason = "database file";
            return true;
        }

        string fileName = Path.GetFileName(path);
        if (fileName.EndsWith(".secret.json", StringComparison.OrdinalIgnoreCase))
        {
            reason = "protected secret envelope";
            return true;
        }

        if (path.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            .Any(part => string.Equals(part, "protected-secrets", StringComparison.OrdinalIgnoreCase)))
        {
            reason = "protected secret directory";
            return true;
        }

        if (!TextExtensions.Contains(extension))
        {
            reason = "non-text artifact";
            return true;
        }

        reason = string.Empty;
        return false;
    }

    private static string ReadBoundedText(string path, long maxBytes)
    {
        var info = new FileInfo(path);
        if (info.Length <= maxBytes)
        {
            return File.ReadAllText(path, Encoding.UTF8);
        }

        long offset = Math.Max(0, info.Length - maxBytes);
        using FileStream stream = File.OpenRead(path);
        stream.Seek(offset, SeekOrigin.Begin);
        using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
        string tail = reader.ReadToEnd();
        return $"[truncated to last {maxBytes} bytes from {info.Length} byte artifact]{Environment.NewLine}{tail}";
    }

    private static string EntryName(string root, string fullPath)
    {
        string normalizedRoot = string.IsNullOrWhiteSpace(root) ? "openburnbar-support" : SanitizeSegment(root);
        string artifact = fullPath.Replace(Path.DirectorySeparatorChar, '/').Replace(Path.AltDirectorySeparatorChar, '/');
        artifact = artifact.TrimStart('/').Replace(':', '_');
        return normalizedRoot + "/" + artifact;
    }

    private static string SanitizeSegment(string value)
    {
        var builder = new StringBuilder(value.Length);
        foreach (char c in value)
        {
            builder.Append(char.IsLetterOrDigit(c) || c is '-' or '_' or '.' ? c : '-');
        }

        return builder.Length == 0 ? "openburnbar-support" : builder.ToString();
    }
}
