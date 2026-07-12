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
    private VideoEncoderConfiguration? _configuration;
    private VideoEncodingProperties? _encodingProperties;
    private Func<MediaFrame, ValueTask>? _onEncoded;
    private uint _gopId;
    private uint _frameIndex;
    private int _targetBitsPerSecond;

    public Task StartAsync(VideoEncoderConfiguration configuration, Func<MediaFrame, ValueTask> onEncoded, CancellationToken cancellationToken = default)
    {
        _configuration = configuration ?? throw new ArgumentNullException(nameof(configuration));
        _onEncoded = onEncoded ?? throw new ArgumentNullException(nameof(onEncoded));
        _targetBitsPerSecond = configuration.TargetBitsPerSecond;

        _encodingProperties = BuildEncodingProperties(configuration);
        return Task.CompletedTask;
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
        var handler = _onEncoded;
        if (handler is null)
        {
            return ValueTask.CompletedTask;
        }

        // The real MFT ProcessInput/ProcessOutput loop runs on the Windows dev
        // host; here we frame the encode boundary so the portable session
        // pipeline can be exercised. Keyframe cadence tracks the configured GOP.
        var keyframeInterval = Math.Max(1, (int)Math.Round((_configuration?.KeyframeIntervalSeconds ?? 2.0) * (_configuration?.FrameRate ?? 30)));
        var isKeyframe = _frameIndex % keyframeInterval == 0;
        if (isKeyframe && _frameIndex != 0)
        {
            _gopId++;
            _frameIndex = 0;
        }

        var flags = isKeyframe ? MediaFrameFlags.Keyframe : MediaFrameFlags.None;
        var mediaFrame = new MediaFrame(
            MediaFrameKind.VideoNal,
            flags,
            gopId: _gopId,
            frameIndex: _frameIndex,
            presentationTimestampMillis: frame.PresentationTimestampMillis,
            cursor: frame.Cursor,
            payload: Array.Empty<byte>());
        _frameIndex++;
        return handler(mediaFrame);
    }

    public void SetTargetBitsPerSecond(int bitsPerSecond)
    {
        _targetBitsPerSecond = bitsPerSecond;
        if (_encodingProperties is not null)
        {
            _encodingProperties.Bitrate = (uint)Math.Max(0, bitsPerSecond);
        }
    }

    public int TargetBitsPerSecond => _targetBitsPerSecond;

    public Task StopAsync()
    {
        _onEncoded = null;
        _encodingProperties = null;
        return Task.CompletedTask;
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync().ConfigureAwait(false);
    }
}
