using OpenBurnBar.App.Settings.ViewModels;
using Xunit;

namespace OpenBurnBar.App.Settings.ViewModels.Tests;

public sealed class MediaSettingsViewModelTests
{
    [Fact]
    public void HealthyFileTransferRuntime_ReportsBothSafetyGates()
    {
        var runtime = new FakeRuntime(Healthy());
        var viewModel = new MediaSettingsViewModel(runtime);

        Assert.True(viewModel.OutboundSnapshotsReady);
        Assert.True(viewModel.OriginMarkerReady);
        Assert.True(viewModel.ThreatScannerReady);
        Assert.True(viewModel.InboundProtectionReady);
        Assert.Contains("explicit approval", viewModel.SafetySummary);
        Assert.Contains("not certified", viewModel.ScreenShareStatus);
    }

    [Fact]
    public void MissingScanner_ReportsFailClosedInboundState()
    {
        MediaRuntimeStatusSnapshot status = Healthy() with { ThreatScannerReady = false };
        var viewModel = new MediaSettingsViewModel(new FakeRuntime(status));

        Assert.True(viewModel.OutboundSnapshotsReady);
        Assert.False(viewModel.InboundProtectionReady);
        Assert.Contains("promotion is disabled", viewModel.SafetySummary);
    }

    [Fact]
    public void RefreshStatus_ReplacesTheRuntimeSnapshot()
    {
        var runtime = new FakeRuntime(Healthy() with { QuarantinedFileCount = 1 });
        var viewModel = new MediaSettingsViewModel(runtime);
        runtime.Status = Healthy() with { QuarantinedFileCount = 3 };

        viewModel.RefreshStatus();

        Assert.Equal(3, viewModel.QuarantinedFileCount);
    }

    [Fact]
    public void OpenDownloadFolder_DelegatesToRuntime()
    {
        var runtime = new FakeRuntime(Healthy()) { OpenResult = true };
        var viewModel = new MediaSettingsViewModel(runtime);

        Assert.True(viewModel.OpenDownloadFolder());
        Assert.True(runtime.OpenCalled);
    }

    private static MediaRuntimeStatusSnapshot Healthy() => new(
        OutboundSnapshotsReady: true,
        OriginMarkerReady: true,
        ThreatScannerReady: true,
        QuarantinedFileCount: 0,
        SnapshotDirectory: "snapshots",
        DownloadDirectory: "downloads",
        ScreenShareStatus: "Unavailable: not certified.",
        MicrophoneStatus: "Unavailable: not certified.",
        CameraStatus: "Unavailable: not certified.");

    private sealed class FakeRuntime(MediaRuntimeStatusSnapshot status) : IMediaRuntimeStatusProvider
    {
        public MediaRuntimeStatusSnapshot Status { get; set; } = status;

        public bool OpenResult { get; init; }

        public bool OpenCalled { get; private set; }

        public MediaRuntimeStatusSnapshot GetStatus() => Status;

        public bool OpenDownloadFolder()
        {
            OpenCalled = true;
            return OpenResult;
        }
    }
}
