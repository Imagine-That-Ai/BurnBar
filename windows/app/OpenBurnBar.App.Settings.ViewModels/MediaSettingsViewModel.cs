using System;

namespace OpenBurnBar.App.Settings.ViewModels;

public sealed record MediaRuntimeStatusSnapshot(
    bool OutboundSnapshotsReady,
    bool OriginMarkerReady,
    bool ThreatScannerReady,
    int QuarantinedFileCount,
    string SnapshotDirectory,
    string DownloadDirectory,
    string ScreenShareStatus,
    string MicrophoneStatus,
    string CameraStatus);

public interface IMediaRuntimeStatusProvider
{
    MediaRuntimeStatusSnapshot GetStatus();

    bool OpenDownloadFolder();
}

public sealed class UnavailableMediaRuntimeStatusProvider : IMediaRuntimeStatusProvider
{
    public static readonly UnavailableMediaRuntimeStatusProvider Instance = new();

    private UnavailableMediaRuntimeStatusProvider()
    {
    }

    public MediaRuntimeStatusSnapshot GetStatus() => new(
        false,
        false,
        false,
        0,
        "Unavailable",
        "Unavailable",
        "Unavailable: Windows capture-to-transport pipeline is not certified.",
        "Unavailable: Windows audio-to-transport pipeline is not certified.",
        "Unavailable: Windows camera-to-transport pipeline is not certified.");

    public bool OpenDownloadFolder() => false;
}

/// <summary>Truthful Windows Mercury status and file-transfer safety controls.</summary>
public sealed class MediaSettingsViewModel : ObservableSettingsViewModel
{
    private readonly IMediaRuntimeStatusProvider _runtime;
    private MediaRuntimeStatusSnapshot _status;

    public MediaSettingsViewModel(IMediaRuntimeStatusProvider? runtime = null)
    {
        _runtime = runtime ?? UnavailableMediaRuntimeStatusProvider.Instance;
        _status = _runtime.GetStatus();
    }

    public string Title => "Media (Mercury)";

    public string SafetySummary => InboundProtectionReady
        ? "Outbound files are immutable snapshots. Inbound files stay quarantined until MOTW, Defender, and explicit approval pass."
        : "Inbound promotion is disabled because MOTW or Microsoft Defender is unavailable.";

    public bool OutboundSnapshotsReady => _status.OutboundSnapshotsReady;

    public bool OriginMarkerReady => _status.OriginMarkerReady;

    public bool ThreatScannerReady => _status.ThreatScannerReady;

    public bool InboundProtectionReady => _status.OriginMarkerReady && _status.ThreatScannerReady;

    public int QuarantinedFileCount => _status.QuarantinedFileCount;

    public string SnapshotDirectory => _status.SnapshotDirectory;

    public string DownloadDirectory => _status.DownloadDirectory;

    public string ScreenShareStatus => _status.ScreenShareStatus;

    public string MicrophoneStatus => _status.MicrophoneStatus;

    public string CameraStatus => _status.CameraStatus;

    public void RefreshStatus()
    {
        _status = _runtime.GetStatus();
        OnPropertyChanged(string.Empty);
    }

    public bool OpenDownloadFolder() => _runtime.OpenDownloadFolder();
}
