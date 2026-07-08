using System;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Integrations.Mercury.Wire;

namespace OpenBurnBar.Integrations.Mercury.Adapters;

/// <summary>
/// Platform seam interfaces the Windows-native adapters
/// (<c>OpenBurnBar.Integrations.Mercury.Windows</c>) implement:
/// Windows.Graphics.Capture screen mirror, WASAPI audio, MediaCapture camera,
/// MediaFoundation encode, and the APNs-VoIP → Windows-push substitute. The
/// portable session/gate logic composes these without knowing which OS provides
/// them. On macOS the interfaces compile and are exercised by fakes; the
/// concrete Windows implementations are Windows-CI / dev-host deferred.
/// </summary>
public readonly struct CapturedFrame
{
    /// <summary>Raw frame payload (e.g. BGRA pixels for video, PCM for audio).</summary>
    public byte[] Data { get; }

    /// <summary>Frame width in pixels (0 for audio).</summary>
    public int Width { get; }

    /// <summary>Frame height in pixels (0 for audio).</summary>
    public int Height { get; }

    /// <summary>Presentation timestamp in milliseconds.</summary>
    public ulong PresentationTimestampMillis { get; }

    /// <summary>Optional cursor location captured with the frame.</summary>
    public CursorMetadata? Cursor { get; }

    public CapturedFrame(byte[] data, int width, int height, ulong presentationTimestampMillis, CursorMetadata? cursor = null)
    {
        Data = data ?? Array.Empty<byte>();
        Width = width;
        Height = height;
        PresentationTimestampMillis = presentationTimestampMillis;
        Cursor = cursor;
    }
}

/// <summary>Configuration for a screen-capture session.</summary>
public sealed class ScreenCaptureConfiguration
{
    /// <summary>Target display id (null = primary).</summary>
    public string? DisplayId { get; init; }

    /// <summary>Target window handle (null = whole display).</summary>
    public long? WindowHandle { get; init; }

    /// <summary>Whether to include the cursor in the captured frames.</summary>
    public bool CaptureCursor { get; init; }
}

/// <summary>Windows.Graphics.Capture screen mirror source (parity: ScreenCapturePipeline).</summary>
public interface IScreenCaptureSource : IAsyncDisposable
{
    Task StartAsync(ScreenCaptureConfiguration configuration, Func<CapturedFrame, ValueTask> onFrame, CancellationToken cancellationToken = default);

    Task StopAsync();
}

/// <summary>WASAPI microphone / system-audio source (parity: MicrophoneCapturePipeline).</summary>
public interface IAudioCaptureSource : IAsyncDisposable
{
    Task StartAsync(Func<CapturedFrame, ValueTask> onFrame, CancellationToken cancellationToken = default);

    Task StopAsync();

    /// <summary>Whether the mic is muted; muted frames carry <see cref="MediaFrameFlags.Muted"/>.</summary>
    bool IsMuted { get; set; }
}

/// <summary>MediaCapture camera source (parity: CameraCapturePipeline).</summary>
public interface ICameraCaptureSource : IAsyncDisposable
{
    Task StartAsync(Func<CapturedFrame, ValueTask> onFrame, CancellationToken cancellationToken = default);

    Task StopAsync();
}

/// <summary>Configuration for the MediaFoundation encoder (parity: VideoEncoder.Configuration).</summary>
public sealed class VideoEncoderConfiguration
{
    public int Width { get; init; } = 1920;

    public int Height { get; init; } = 1080;

    public int TargetBitsPerSecond { get; init; }

    public double KeyframeIntervalSeconds { get; init; } = 2.0;

    public int FrameRate { get; init; } = 30;

    public string PreferredCodec { get; init; } = "hevc";
}

/// <summary>MediaFoundation H.264/HEVC encoder that emits <see cref="MediaFrame"/> (parity: VideoEncoder).</summary>
public interface IVideoEncoder : IAsyncDisposable
{
    Task StartAsync(VideoEncoderConfiguration configuration, Func<MediaFrame, ValueTask> onEncoded, CancellationToken cancellationToken = default);

    ValueTask EncodeAsync(CapturedFrame frame);

    void SetTargetBitsPerSecond(int bitsPerSecond);

    Task StopAsync();
}

/// <summary>Where encoded frames land (parity: MediaStreamSink over the iroh stream).</summary>
public interface IMediaStreamSink
{
    ValueTask WriteAsync(MediaFrame frame);

    ValueTask CloseAsync();
}

/// <summary>
/// The APNs-VoIP → Windows-push substitute (parity: VoIPCallTrigger). On iOS the
/// Mac pings an APNs VoIP push to wake the phone; on Windows the wake is a WNS
/// raw push / toast, so the trigger is abstracted behind this seam.
/// </summary>
public interface IVoipPushTrigger
{
    /// <summary>
    /// Wake the peer device for an incoming media session. Returns whether the
    /// push was accepted for delivery.
    /// </summary>
    Task<bool> TriggerAsync(string peerDeviceId, string sessionId, CancellationToken cancellationToken = default);
}
