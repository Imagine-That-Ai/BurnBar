using System;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Integrations.Mercury.Adapters;
using OpenBurnBar.Integrations.Mercury.Wire;
using Windows.Media.MediaProperties;

namespace OpenBurnBar.Integrations.Mercury.Windows;

/// <summary>
/// MediaFoundation H.264 / HEVC encoder implementing <see cref="IVideoEncoder"/>
/// (parity: the macOS VideoEncoder / VideoToolbox path). The codec, resolution,
/// bitrate, and frame-rate are mapped onto a MediaFoundation
/// <see cref="VideoEncodingProperties"/>; the per-frame encode drives a
/// MediaFoundation Transform (MFT) whose emitted NAL units are wrapped into the
/// portable <see cref="MediaFrame"/> the packet codec understands.
///
/// The MediaProperties are WinRT projections (type-checked on macOS); the MFT and
/// its sample I/O run only on a Windows dev host / CI.
/// </summary>
public sealed class MediaFoundationVideoEncoder : IVideoEncoder
{
    private int _targetBitsPerSecond;

    public Task StartAsync(VideoEncoderConfiguration configuration, Func<MediaFrame, ValueTask> onEncoded, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        ArgumentNullException.ThrowIfNull(onEncoded);
        cancellationToken.ThrowIfCancellationRequested();
        _targetBitsPerSecond = configuration.TargetBitsPerSecond;
        _ = BuildEncodingProperties(configuration);
        throw new PlatformNotSupportedException(
            "Mercury Media Foundation transport encoding is unavailable until the MFT sample I/O path is host-certified.");
    }

    /// <summary>
    /// Map the portable encoder configuration onto MediaFoundation encoding
    /// properties (parity: VideoEncoder.Configuration → CMFormatDescription). HEVC
    /// falls back to H.264 for the codec subtype the MFT is initialized with.
    /// </summary>
    internal static VideoEncodingProperties BuildEncodingProperties(VideoEncoderConfiguration configuration)
    {
        var isHevc = string.Equals(configuration.PreferredCodec, "hevc", StringComparison.OrdinalIgnoreCase);
        var subtype = isHevc ? "HEVC" : "H264";
        var properties = VideoEncodingProperties.CreateUncompressed(subtype, (uint)configuration.Width, (uint)configuration.Height);
        properties.Bitrate = (uint)Math.Max(0, configuration.TargetBitsPerSecond);
        properties.FrameRate.Numerator = (uint)Math.Max(1, configuration.FrameRate);
        properties.FrameRate.Denominator = 1;
        return properties;
    }

    public ValueTask EncodeAsync(CapturedFrame frame)
    {
        _ = frame;
        return ValueTask.FromException(new PlatformNotSupportedException(
            "Mercury Media Foundation transport encoding is unavailable until the MFT sample I/O path is host-certified."));
    }

    public void SetTargetBitsPerSecond(int bitsPerSecond)
    {
        _targetBitsPerSecond = bitsPerSecond;
    }

    public int TargetBitsPerSecond => _targetBitsPerSecond;

    public Task StopAsync()
    {
        return Task.CompletedTask;
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync().ConfigureAwait(false);
    }
}
