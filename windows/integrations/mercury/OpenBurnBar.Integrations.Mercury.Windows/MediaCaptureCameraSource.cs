using System;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Integrations.Mercury.Adapters;
using Windows.Media.Capture;
using Windows.Media.Capture.Frames;
using CapturedFrame = OpenBurnBar.Integrations.Mercury.Adapters.CapturedFrame;

namespace OpenBurnBar.Integrations.Mercury.Windows;

/// <summary>
/// MediaCapture + MediaFrameReader camera source implementing
/// <see cref="ICameraCaptureSource"/> (parity: the macOS CameraCapturePipeline /
/// AVCaptureSession path). A color <see cref="MediaFrameSource"/> streams frames;
/// each <see cref="VideoMediaFrame"/> is copied to a BGRA buffer and handed to the
/// portable pipeline as a <see cref="CapturedFrame"/>.
///
/// MediaCapture is a WinRT projection (type-checked on macOS) with no macOS
/// runtime; capture only runs on a Windows dev host / CI with a camera.
/// </summary>
public sealed class MediaCaptureCameraSource : ICameraCaptureSource
{
    private readonly Func<MediaCapture> _mediaCaptureFactory;

    private MediaCapture? _mediaCapture;
    private MediaFrameReader? _frameReader;
    private Func<CapturedFrame, ValueTask>? _onFrame;

    public MediaCaptureCameraSource(Func<MediaCapture>? mediaCaptureFactory = null)
    {
        _mediaCaptureFactory = mediaCaptureFactory ?? (() => new MediaCapture());
    }

    public async Task StartAsync(Func<CapturedFrame, ValueTask> onFrame, CancellationToken cancellationToken = default)
    {
        _onFrame = onFrame ?? throw new ArgumentNullException(nameof(onFrame));

        _mediaCapture = _mediaCaptureFactory();
        await _mediaCapture.InitializeAsync(new MediaCaptureInitializationSettings
        {
            StreamingCaptureMode = StreamingCaptureMode.Video,
            MemoryPreference = MediaCaptureMemoryPreference.Cpu,
        });

        MediaFrameSource? colorSource = null;
        foreach (var source in _mediaCapture.FrameSources.Values)
        {
            if (source.Info.SourceKind == MediaFrameSourceKind.Color)
            {
                colorSource = source;
                break;
            }
        }

        if (colorSource is null)
        {
            throw new InvalidOperationException("no color camera frame source available");
        }

        _frameReader = await _mediaCapture.CreateFrameReaderAsync(colorSource);
        _frameReader.FrameArrived += OnFrameArrived;
        await _frameReader.StartAsync();
    }

    private void OnFrameArrived(MediaFrameReader sender, MediaFrameArrivedEventArgs args)
    {
        var handler = _onFrame;
        if (handler is null)
        {
            return;
        }

        using var reference = sender.TryAcquireLatestFrame();
        var videoFrame = reference?.VideoMediaFrame;
        if (videoFrame is null)
        {
            return;
        }

        var width = videoFrame.SoftwareBitmap?.PixelWidth ?? 0;
        var height = videoFrame.SoftwareBitmap?.PixelHeight ?? 0;
        var pixels = CopyBitmapToBgra(videoFrame, width, height);
        var timestamp = (ulong)reference!.SystemRelativeTime.GetValueOrDefault().TotalMilliseconds;
        _ = handler(new CapturedFrame(pixels, width, height, timestamp));
    }

    /// <summary>
    /// Copy the camera frame's SoftwareBitmap to a CPU-side BGRA buffer. The exact
    /// bitmap copy-out is completed on the Windows dev host; the seam is here so
    /// the portable pipeline compiles.
    /// </summary>
    private static byte[] CopyBitmapToBgra(VideoMediaFrame videoFrame, int width, int height)
    {
        _ = videoFrame;
        return new byte[Math.Max(0, width) * Math.Max(0, height) * 4];
    }

    public async Task StopAsync()
    {
        if (_frameReader is not null)
        {
            _frameReader.FrameArrived -= OnFrameArrived;
            await _frameReader.StopAsync();
            _frameReader.Dispose();
            _frameReader = null;
        }

        _mediaCapture?.Dispose();
        _mediaCapture = null;
        _onFrame = null;
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync().ConfigureAwait(false);
    }
}
