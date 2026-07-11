using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Windows.Foundation;
using Windows.Graphics.DirectX.Direct3D11;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace OpenBurnBar.Integrations.Mercury.Windows;

internal static class WindowsMediaBufferReader
{
    private const int BytesPerBgraPixel = 4;
    private const int MaxFrameBytes = 256 * 1024 * 1024;

    public static async Task<SoftwareBitmapBytes> ReadSurfaceBgraAsync(
        IDirect3DSurface surface,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(surface);
        using SoftwareBitmap bitmap = await SoftwareBitmap
            .CreateCopyFromSurfaceAsync(surface, BitmapAlphaMode.Premultiplied)
            .AsTask(cancellationToken)
            .ConfigureAwait(false);
        return ReadBitmapBgra(bitmap);
    }

    public static SoftwareBitmapBytes ReadBitmapBgra(SoftwareBitmap bitmap)
    {
        ArgumentNullException.ThrowIfNull(bitmap);
        SoftwareBitmap? converted = null;
        SoftwareBitmap source = bitmap;
        if (bitmap.BitmapPixelFormat != BitmapPixelFormat.Bgra8
            || bitmap.BitmapAlphaMode != BitmapAlphaMode.Premultiplied)
        {
            converted = SoftwareBitmap.Convert(bitmap, BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
            source = converted;
        }

        try
        {
            int length = CheckedBgraLength(source.PixelWidth, source.PixelHeight);
            var buffer = new global::Windows.Storage.Streams.Buffer((uint)length)
            {
                Length = (uint)length,
            };
            source.CopyToBuffer(buffer);
            var bytes = new byte[length];
            using var reader = DataReader.FromBuffer(buffer);
            reader.ReadBytes(bytes);
            return new SoftwareBitmapBytes(bytes, source.PixelWidth, source.PixelHeight);
        }
        finally
        {
            converted?.Dispose();
        }
    }

    public static byte[] ReadAudioBuffer(global::Windows.Media.AudioBuffer buffer)
    {
        ArgumentNullException.ThrowIfNull(buffer);
        int length = checked((int)buffer.Length);
        if (length == 0)
        {
            return Array.Empty<byte>();
        }

        if (length > MaxFrameBytes)
        {
            throw new InvalidOperationException("Audio frame exceeds the bounded media-frame size.");
        }

        using IMemoryBufferReference reference = buffer.CreateReference();
        var access = (IMemoryBufferByteAccess)reference;
        Marshal.ThrowExceptionForHR(access.GetBuffer(out IntPtr pointer, out uint capacity));
        if (pointer == IntPtr.Zero || length > capacity)
        {
            throw new InvalidOperationException("Audio frame buffer is unavailable or shorter than its declared length.");
        }

        var bytes = new byte[length];
        Marshal.Copy(pointer, bytes, 0, length);
        return bytes;
    }

    private static int CheckedBgraLength(int width, int height)
    {
        if (width <= 0 || height <= 0)
        {
            throw new InvalidOperationException("Captured frame dimensions must be positive.");
        }

        long length = checked((long)width * height * BytesPerBgraPixel);
        if (length > MaxFrameBytes)
        {
            throw new InvalidOperationException("Captured frame exceeds the bounded media-frame size.");
        }

        return checked((int)length);
    }

    [ComImport]
    [Guid("5B0D3235-4DBA-4D44-8650-1C0D0E4FD04D")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMemoryBufferByteAccess
    {
        [PreserveSig]
        int GetBuffer(out IntPtr value, out uint capacity);
    }
}

internal readonly record struct SoftwareBitmapBytes(byte[] Bytes, int Width, int Height);
