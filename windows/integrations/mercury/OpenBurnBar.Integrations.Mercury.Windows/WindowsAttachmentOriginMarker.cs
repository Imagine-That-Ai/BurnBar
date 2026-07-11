using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Integrations.Mercury.FileTransfer;

namespace OpenBurnBar.Integrations.Mercury.Windows;

/// <summary>Writes the NTFS Mark-of-the-Web alternate data stream before a file can leave quarantine.</summary>
public sealed class WindowsAttachmentOriginMarker : IInboundFileOriginMarker
{
    public const string ProviderName = "NTFS Zone.Identifier";

    public async ValueTask<FileOriginMarkResult> MarkInternetOriginAsync(
        string filePath,
        string sourcePeerHash,
        CancellationToken cancellationToken = default)
    {
        if (!OperatingSystem.IsWindows())
        {
            return new FileOriginMarkResult(FileOriginMarkStatus.Unavailable, ProviderName, "Windows is required for MOTW.");
        }

        try
        {
            ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
            string fullPath = Path.GetFullPath(filePath);
            if (!File.Exists(fullPath))
            {
                return new FileOriginMarkResult(FileOriginMarkStatus.Failed, ProviderName, "Quarantined file is missing.");
            }

            string zone = BuildZoneIdentifier(sourcePeerHash);
            await File.WriteAllTextAsync(
                fullPath + ":Zone.Identifier",
                zone,
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
                cancellationToken).ConfigureAwait(false);
            return new FileOriginMarkResult(FileOriginMarkStatus.Marked, ProviderName, "Internet zone marker written.");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            return new FileOriginMarkResult(FileOriginMarkStatus.Failed, ProviderName, ex.GetType().Name);
        }
    }

    public static string BuildZoneIdentifier(string sourcePeerHash)
    {
        string peer = NormalizeHash(sourcePeerHash);
        return "[ZoneTransfer]\r\n"
            + "ZoneId=3\r\n"
            + "ReferrerUrl=mercury://openburnbar\r\n"
            + $"HostUrl=mercury://peer/{peer}\r\n";
    }

    public static bool HasInternetZone(string filePath)
    {
        if (!OperatingSystem.IsWindows())
        {
            return false;
        }

        try
        {
            string zone = File.ReadAllText(Path.GetFullPath(filePath) + ":Zone.Identifier");
            return zone.Contains("ZoneId=3", StringComparison.Ordinal);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            return false;
        }
    }

    public bool HasInternetOrigin(string filePath) => HasInternetZone(filePath);

    private static string NormalizeHash(string value)
    {
        if (value is null || value.Length != 64)
        {
            return new string('0', 64);
        }

        var builder = new StringBuilder(64);
        foreach (char character in value)
        {
            builder.Append(Uri.IsHexDigit(character) ? char.ToLowerInvariant(character) : '0');
        }

        return builder.ToString();
    }
}
