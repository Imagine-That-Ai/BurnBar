// IScreenCapturer over Windows.Graphics.Capture (WGC).
//
// The app supplies a GraphicsCaptureItem (from the WinUI GraphicsCapturePicker
// or a monitor/window handle) and an IDirect3DDevice; this adapter owns the
// frame-pool lifecycle, grabs a single frame, copies it to a CPU SoftwareBitmap,
// and PNG-encodes it. The content hash is what the audit chain records (the
// screenshot itself stays private at rest, mirroring Decision 8).
//
// Windows-only at runtime (WGC + D3D). Roslyn-compiles on the macOS authoring
// host via the Windows SDK WinRT projections; the live capture proof is a
// Windows dev-host task.

using System;
using System.Threading;
using System.Threading.Tasks;
using System.Runtime.Versioning;
using OpenBurnBar.ComputerUse.Core.Adapters;
using OpenBurnBar.ComputerUse.Core.Crypto;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace OpenBurnBar.ComputerUse.Windows;

/// <summary>Single-frame screenshot capturer backed by Windows.Graphics.Capture.</summary>
[SupportedOSPlatform("windows10.0.19041.0")]
public sealed class WindowsGraphicsCaptureScreenCapturer : IScreenCapturer, IDisposable
{
    private readonly GraphicsCaptureItem _item;
    private readonly IDirect3DDevice _device;
    private readonly bool _ownsResources;
    private bool _disposed;

    public WindowsGraphicsCaptureScreenCapturer(
        GraphicsCaptureItem item,
        IDirect3DDevice device,
        bool ownsResources = false)
    {
        _item = item ?? throw new ArgumentNullException(nameof(item));
        _device = device ?? throw new ArgumentNullException(nameof(device));
        _ownsResources = ownsResources;
    }

    public async Task<ScreenCapture> CaptureAsync(CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        var completion = new TaskCompletionSource<Direct3D11CaptureFrame>(
            TaskCreationOptions.RunContinuationsAsynchronously);

        using var framePool = Direct3D11CaptureFramePool.CreateFreeThreaded(
            _device,
            DirectXPixelFormat.B8G8R8A8UIntNormalized,
            numberOfBuffers: 1,
            _item.Size);

        void OnFrameArrived(Direct3D11CaptureFramePool pool, object args)
        {
            var frame = pool.TryGetNextFrame();
            if (frame is not null)
            {
                completion.TrySetResult(frame);
            }
        }

        framePool.FrameArrived += OnFrameArrived;
        var session = framePool.CreateCaptureSession(_item);
        try
        {
            using var registration = cancellationToken.Register(() => completion.TrySetCanceled(cancellationToken));
            session.StartCapture();

            using var frame = await completion.Task.ConfigureAwait(false);
            using var bitmap = await SoftwareBitmap
                .CreateCopyFromSurfaceAsync(frame.Surface, BitmapAlphaMode.Premultiplied)
                .AsTask(cancellationToken)
                .ConfigureAwait(false);

            var png = await EncodePngAsync(bitmap, cancellationToken).ConfigureAwait(false);
            return new ScreenCapture(png, AuditHasher.Current.Hash(png));
        }
        finally
        {
            framePool.FrameArrived -= OnFrameArrived;
            session.Dispose();
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        if (_ownsResources)
        {
            (_device as IDisposable)?.Dispose();
        }
    }

    private static async Task<byte[]> EncodePngAsync(SoftwareBitmap bitmap, CancellationToken cancellationToken)
    {
        using var stream = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream)
            .AsTask(cancellationToken)
            .ConfigureAwait(false);
        encoder.SetSoftwareBitmap(bitmap);
        await encoder.FlushAsync().AsTask(cancellationToken).ConfigureAwait(false);

        var length = (int)stream.Size;
        var bytes = new byte[length];
        using var reader = new DataReader(stream.GetInputStreamAt(0));
        await reader.LoadAsync((uint)length).AsTask(cancellationToken).ConfigureAwait(false);
        reader.ReadBytes(bytes);
        return bytes;
    }
}
