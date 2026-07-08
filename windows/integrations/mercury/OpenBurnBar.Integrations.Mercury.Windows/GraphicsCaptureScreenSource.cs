using System;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Integrations.Mercury.Adapters;
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

    private Direct3D11CaptureFramePool? _framePool;
    private GraphicsCaptureSession? _session;
    private Func<CapturedFrame, ValueTask>? _onFrame;
    private ulong _frameCounter;

    public GraphicsCaptureScreenSource(IDirect3DDevice device, Func<GraphicsCaptureItem> itemFactory)
    {
        _device = device ?? throw new ArgumentNullException(nameof(device));
        _itemFactory = itemFactory ?? throw new ArgumentNullException(nameof(itemFactory));
    }

    public Task StartAsync(ScreenCaptureConfiguration configuration, Func<CapturedFrame, ValueTask> onFrame, CancellationToken cancellationToken = default)
    {
        if (configuration is null)
        {
            throw new ArgumentNullException(nameof(configuration));
        }

        _onFrame = onFrame ?? throw new ArgumentNullException(nameof(onFrame));

        var item = _itemFactory();
        var size = item.Size;
        _framePool = Direct3D11CaptureFramePool.Create(
            _device,
            DirectXPixelFormat.B8G8R8A8UIntNormalized,
            numberOfBuffers: 2,
            size);
        _framePool.FrameArrived += OnFrameArrived;

        _session = _framePool.CreateCaptureSession(item);
        // IsCursorCaptureEnabled requires Windows 10.0.19041+; guard so the
        // adapter still starts on the 17763 floor (parity: the cursor toggle is
        // best-effort on the mirror path).
        if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        {
            _session.IsCursorCaptureEnabled = configuration.CaptureCursor;
        }

        _session.StartCapture();
        return Task.CompletedTask;
    }

    private void OnFrameArrived(Direct3D11CaptureFramePool sender, object args)
    {
        var handler = _onFrame;
        if (handler is null)
        {
            return;
        }

        using var frame = sender.TryGetNextFrame();
        if (frame is null)
        {
            return;
        }

        var width = frame.ContentSize.Width;
        var height = frame.ContentSize.Height;
        var pixels = CopySurfaceToBgra(frame.Surface, width, height);
        var timestamp = (ulong)frame.SystemRelativeTime.TotalMilliseconds;
        _frameCounter++;

        _ = handler(new CapturedFrame(pixels, width, height, timestamp));
    }

    /// <summary>
    /// Copy the captured Direct3D surface to a CPU-side BGRA buffer. The concrete
    /// staging-texture readback is filled in on the Windows dev host (it needs the
    /// D3D11 device context); the seam is here so the portable pipeline compiles.
    /// </summary>
    private static byte[] CopySurfaceToBgra(IDirect3DSurface surface, int width, int height)
    {
        _ = surface;
        return new byte[Math.Max(0, width) * Math.Max(0, height) * 4];
    }

    public Task StopAsync()
    {
        _session?.Dispose();
        _session = null;
        if (_framePool is not null)
        {
            _framePool.FrameArrived -= OnFrameArrived;
            _framePool.Dispose();
            _framePool = null;
        }

        _onFrame = null;
        return Task.CompletedTask;
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync().ConfigureAwait(false);
    }
}
