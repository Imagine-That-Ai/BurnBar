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
    private readonly SemaphoreSlim _frameGate = new(1, 1);

    private MediaCapture? _mediaCapture;
    private MediaFrameReader? _frameReader;
    private CancellationTokenSource? _captureCancellation;
    private Func<CapturedFrame, ValueTask>? _onFrame;
    private bool _disposed;

    public MediaCaptureCameraSource(Func<MediaCapture>? mediaCaptureFactory = null)
    {
        _mediaCaptureFactory = mediaCaptureFactory ?? (() => new MediaCapture());
    }

    public Exception? LastError { get; private set; }

    public async Task StartAsync(Func<CapturedFrame, ValueTask> onFrame, CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentNullException.ThrowIfNull(onFrame);
        cancellationToken.ThrowIfCancellationRequested();
        if (_mediaCapture is not null)
        {
            throw new InvalidOperationException("Camera capture is already running.");
        }

        _onFrame = onFrame;
        LastError = null;
        _captureCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);

        try
        {
            _mediaCapture = _mediaCaptureFactory();
            await _mediaCapture.InitializeAsync(new MediaCaptureInitializationSettings
            {
                StreamingCaptureMode = StreamingCaptureMode.Video,
                MemoryPreference = MediaCaptureMemoryPreference.Cpu,
            });
            cancellationToken.ThrowIfCancellationRequested();

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
                throw new InvalidOperationException("No color camera frame source is available.");
            }

            _frameReader = await _mediaCapture.CreateFrameReaderAsync(colorSource);
            _frameReader.FrameArrived += OnFrameArrived;
            MediaFrameReaderStartStatus startStatus = await _frameReader.StartAsync();
            cancellationToken.ThrowIfCancellationRequested();
            if (startStatus != MediaFrameReaderStartStatus.Success)
            {
                throw new InvalidOperationException($"Camera frame reader failed to start: {startStatus}");
            }
        }
        catch
        {
            await StopAsync().ConfigureAwait(false);
            throw;
        }
    }

    private async void OnFrameArrived(MediaFrameReader sender, MediaFrameArrivedEventArgs args)
    {
        var handler = _onFrame;
        var captureCancellation = _captureCancellation;
        if (handler is null || captureCancellation is null || !_frameGate.Wait(0))
        {
            return;
        }

        try
        {
            using var reference = sender.TryAcquireLatestFrame();
            var videoFrame = reference?.VideoMediaFrame;
            if (videoFrame is null)
            {
                return;
            }

            SoftwareBitmapBytes pixels;
            if (videoFrame.SoftwareBitmap is not null)
            {
                pixels = WindowsMediaBufferReader.ReadBitmapBgra(videoFrame.SoftwareBitmap);
            }
            else if (videoFrame.Direct3DSurface is not null)
            {
                pixels = await WindowsMediaBufferReader
                    .ReadSurfaceBgraAsync(videoFrame.Direct3DSurface, captureCancellation.Token)
                    .ConfigureAwait(false);
            }
            else
            {
                throw new InvalidOperationException("Camera frame has neither CPU bitmap nor Direct3D surface data.");
            }

            ulong timestamp = checked((ulong)Math.Max(
                0,
                reference!.SystemRelativeTime.GetValueOrDefault().TotalMilliseconds));
            await handler(new CapturedFrame(
                pixels.Bytes,
                pixels.Width,
                pixels.Height,
                timestamp)).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (captureCancellation.IsCancellationRequested)
        {
        }
        catch (Exception ex)
        {
            LastError = ex;
        }
        finally
        {
            _frameGate.Release();
        }
    }

    public async Task StopAsync()
    {
        Exception? stopError = null;
        _captureCancellation?.Cancel();
        if (_frameReader is not null)
        {
            _frameReader.FrameArrived -= OnFrameArrived;
            try
            {
                await _frameReader.StopAsync();
            }
            catch (Exception ex)
            {
                stopError = ex;
            }
        }

        await _frameGate.WaitAsync().ConfigureAwait(false);
        try
        {
            _frameReader?.Dispose();
            _frameReader = null;
            _mediaCapture?.Dispose();
            _mediaCapture = null;
        }
        finally
        {
            _frameGate.Release();
        }

        _captureCancellation?.Dispose();
        _captureCancellation = null;
        _onFrame = null;

        if (stopError is not null)
        {
            throw stopError;
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }

        await StopAsync().ConfigureAwait(false);
        _disposed = true;
        _frameGate.Dispose();
    }
}
