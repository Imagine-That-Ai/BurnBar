using System;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Integrations.Mercury.Adapters;
using Windows.Graphics;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;

namespace OpenBurnBar.Integrations.Mercury.Windows;

/// <summary>
/// Windows.Graphics.Capture screen / window mirror implementing
/// <see cref="IScreenCaptureSource"/> (parity: the macOS ScreenCapturePipeline
/// / ScreenCaptureKit path). A <see cref="GraphicsCaptureItem"/> feeds a
/// <see cref="Direct3D11CaptureFramePool"/>; each captured surface is copied to a
/// BGRA buffer and handed to the portable session pipeline as a
/// <see cref="CapturedFrame"/>.
///
/// The GraphicsCapture APIs are WinRT projections (type-checked on macOS via the
/// Windows SDK ref pack) with no macOS runtime — the capture session only runs on
/// a Windows dev host / CI.
/// </summary>
public sealed class GraphicsCaptureScreenSource : IScreenCaptureSource
{
    private readonly Func<GraphicsCaptureItem> _itemFactory;
    private readonly IDirect3DDevice _device;
    private readonly bool _ownsDevice;
    private readonly SemaphoreSlim _frameGate = new(1, 1);

    private Direct3D11CaptureFramePool? _framePool;
    private GraphicsCaptureSession? _session;
    private GraphicsCaptureItem? _captureItem;
    private CancellationTokenSource? _captureCancellation;
    private Func<CapturedFrame, ValueTask>? _onFrame;
    private int _frameWidth;
    private int _frameHeight;
    private bool _disposed;

    public GraphicsCaptureScreenSource(
        IDirect3DDevice device,
        Func<GraphicsCaptureItem> itemFactory,
        bool ownsDevice = false)
    {
        _device = device ?? throw new ArgumentNullException(nameof(device));
        _itemFactory = itemFactory ?? throw new ArgumentNullException(nameof(itemFactory));
        _ownsDevice = ownsDevice;
    }

    public static GraphicsCaptureScreenSource CreateForWindow(IntPtr window)
    {
        IDirect3DDevice device = WindowsGraphicsCaptureResources.CreateDirect3DDevice();
        return new GraphicsCaptureScreenSource(
            device,
            () => WindowsGraphicsCaptureResources.CreateItemForWindow(window),
            ownsDevice: true);
    }

    public Exception? LastError { get; private set; }

    public async Task StartAsync(ScreenCaptureConfiguration configuration, Func<CapturedFrame, ValueTask> onFrame, CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (configuration is null)
        {
            throw new ArgumentNullException(nameof(configuration));
        }

        ArgumentNullException.ThrowIfNull(onFrame);
        cancellationToken.ThrowIfCancellationRequested();
        if (_session is not null)
        {
            throw new InvalidOperationException("Screen capture is already running.");
        }

        if (!GraphicsCaptureSession.IsSupported())
        {
            throw new PlatformNotSupportedException("Windows Graphics Capture is unavailable on this host.");
        }

        try
        {
            _onFrame = onFrame;
            LastError = null;
            _captureCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            _captureItem = _itemFactory();
            var size = _captureItem.Size;
            _frameWidth = size.Width;
            _frameHeight = size.Height;
            _framePool = Direct3D11CaptureFramePool.CreateFreeThreaded(
                _device,
                DirectXPixelFormat.B8G8R8A8UIntNormalized,
                numberOfBuffers: 2,
                size);
            _framePool.FrameArrived += OnFrameArrived;

            _session = _framePool.CreateCaptureSession(_captureItem);
            // IsCursorCaptureEnabled requires Windows 10.0.19041+; guard so the
            // adapter still starts on the 17763 floor.
            if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
            {
                _session.IsCursorCaptureEnabled = configuration.CaptureCursor;
            }

            _session.StartCapture();
        }
        catch
        {
            await StopAsync().ConfigureAwait(false);
            throw;
        }
    }

    private async void OnFrameArrived(Direct3D11CaptureFramePool sender, object args)
    {
        var handler = _onFrame;
        var captureCancellation = _captureCancellation;
        Direct3D11CaptureFrame? frame = sender.TryGetNextFrame();
        if (frame is null)
        {
            return;
        }

        if (handler is null || captureCancellation is null || !_frameGate.Wait(0))
        {
            frame.Dispose();
            return;
        }

        CapturedFrame? captured = null;
        SizeInt32? resize = null;
        try
        {
            if (frame.ContentSize.Width != _frameWidth || frame.ContentSize.Height != _frameHeight)
            {
                resize = frame.ContentSize;
            }
            else
            {
                SoftwareBitmapBytes pixels = await WindowsMediaBufferReader
                    .ReadSurfaceBgraAsync(frame.Surface, captureCancellation.Token)
                    .ConfigureAwait(false);
                ulong timestamp = checked((ulong)Math.Max(0, frame.SystemRelativeTime.TotalMilliseconds));
                captured = new CapturedFrame(
                    pixels.Bytes,
                    pixels.Width,
                    pixels.Height,
                    timestamp);
            }
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
            frame.Dispose();
            if (resize is { } size && !captureCancellation.IsCancellationRequested)
            {
                try
                {
                    sender.Recreate(
                        _device,
                        DirectXPixelFormat.B8G8R8A8UIntNormalized,
                        numberOfBuffers: 2,
                        size);
                    _frameWidth = size.Width;
                    _frameHeight = size.Height;
                }
                catch (Exception ex)
                {
                    LastError = ex;
                }
            }

            _frameGate.Release();
        }

        if (resize is not null)
        {
            return;
        }

        if (captured is not null && !captureCancellation.IsCancellationRequested)
        {
            try
            {
                await handler(captured).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (captureCancellation.IsCancellationRequested)
            {
            }
            catch (Exception ex)
            {
                LastError = ex;
            }
        }
    }

    public async Task StopAsync()
    {
        _captureCancellation?.Cancel();
        if (_framePool is not null)
        {
            _framePool.FrameArrived -= OnFrameArrived;
        }

        await _frameGate.WaitAsync().ConfigureAwait(false);
        try
        {
            _session?.Dispose();
            _session = null;
            _captureItem = null;
            _frameWidth = 0;
            _frameHeight = 0;
            _framePool?.Dispose();
            _framePool = null;
        }
        finally
        {
            _frameGate.Release();
        }

        _captureCancellation?.Dispose();
        _captureCancellation = null;
        _onFrame = null;
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }

        await StopAsync().ConfigureAwait(false);
        _disposed = true;
        if (_ownsDevice)
        {
            (_device as IDisposable)?.Dispose();
        }

        _frameGate.Dispose();
    }
}
