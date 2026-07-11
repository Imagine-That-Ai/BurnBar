using System;
using System.Diagnostics;
using System.IO;
using OpenBurnBar.App.Settings.ViewModels;
using OpenBurnBar.Integrations.Mercury.Windows;

namespace OpenBurnBar.App.Media;

/// <summary>Process-wide production owner for the Windows Mercury file-transfer safety runtime.</summary>
internal sealed class WindowsMercuryRuntimeHost : IMediaRuntimeStatusProvider
{
    private static readonly object Gate = new();
    private static WindowsMercuryRuntimeHost? _current;

    private readonly WindowsMercuryFileTransferRuntime _runtime;
    private readonly bool _originMarkerReady;

    private WindowsMercuryRuntimeHost(WindowsMercuryFileTransferRuntime runtime)
    {
        _runtime = runtime;
        _originMarkerReady = ProbeOriginMarker(runtime.SnapshotDirectory);
    }

    public static WindowsMercuryRuntimeHost Current
    {
        get
        {
            lock (Gate)
            {
                return _current ?? throw new InvalidOperationException("Mercury runtime has not been configured.");
            }
        }
    }

    public static void Configure(string settingsDirectory)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(settingsDirectory);
        lock (Gate)
        {
            if (_current is not null)
            {
                return;
            }

            string downloads = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                "Downloads",
                "OpenBurnBar");
            if (string.IsNullOrWhiteSpace(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)))
            {
                downloads = Path.Combine(settingsDirectory, "mercury", "downloads");
            }

            _current = new WindowsMercuryRuntimeHost(
                new WindowsMercuryFileTransferRuntime(settingsDirectory, downloads));
        }
    }

    public WindowsMercuryFileTransferRuntime Runtime => _runtime;

    public MediaRuntimeStatusSnapshot GetStatus() => new(
        OutboundSnapshotsReady: Directory.Exists(_runtime.SnapshotDirectory),
        OriginMarkerReady: _originMarkerReady,
        ThreatScannerReady: _runtime.IsThreatScannerAvailable,
        QuarantinedFileCount: _runtime.QuarantinedFileCount,
        SnapshotDirectory: _runtime.SnapshotDirectory,
        DownloadDirectory: _runtime.DownloadDirectory,
        ScreenShareStatus: "Unavailable: WGC readback is implemented; capture-to-transport encoding is not yet certified.",
        MicrophoneStatus: "Unavailable: PCM readback is implemented; audio transport and device certification remain open.",
        CameraStatus: "Unavailable: bitmap readback is implemented; camera transport and device certification remain open.");

    public bool OpenDownloadFolder()
    {
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = _runtime.DownloadDirectory,
                UseShellExecute = true,
            });
            return true;
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            return false;
        }
    }

    private static bool ProbeOriginMarker(string directory)
    {
        string path = Path.Combine(directory, ".motw-probe-" + Guid.NewGuid().ToString("N"));
        try
        {
            File.WriteAllBytes(path, new byte[] { 0x4f, 0x42, 0x42 });
            var marker = new WindowsAttachmentOriginMarker();
            marker.MarkInternetOriginAsync(path, new string('0', 64)).AsTask().GetAwaiter().GetResult();
            return WindowsAttachmentOriginMarker.HasInternetZone(path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            return false;
        }
        finally
        {
            try
            {
                File.Delete(path);
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }
}
