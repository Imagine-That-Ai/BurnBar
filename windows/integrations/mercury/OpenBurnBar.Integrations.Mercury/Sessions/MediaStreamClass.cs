using System;

namespace OpenBurnBar.Integrations.Mercury.Sessions;

/// <summary>
/// Canonical identifier for a media stream class on the transport. Byte-exact
/// port of <c>OpenBurnBarCore/Sources/OpenBurnBarMedia/MediaStreamClass.swift</c>.
///
/// A string newtype (not a closed enum) so a receiver routes an unknown class to
/// a no-op handler instead of failing to decode — older peers that predate a
/// newer phase's class never crash on a frame they don't understand.
/// </summary>
public readonly struct MediaStreamClass : IEquatable<MediaStreamClass>
{
    public string RawValue { get; }

    public MediaStreamClass(string rawValue)
    {
        RawValue = rawValue ?? throw new ArgumentNullException(nameof(rawValue));
    }

    // Phase 1 — file transfer.
    public static readonly MediaStreamClass BlobAdvertise = new("media.blob.advertise");
    public static readonly MediaStreamClass BlobFetch = new("media.blob.fetch");
    public static readonly MediaStreamClass Blob = new("media.blob");

    // Phase 3 — screen share (Mac/Windows → phone).
    public static readonly MediaStreamClass ScreenVideo = new("media.screen.video");

    // Phase 4 — bidirectional audio.
    public static readonly MediaStreamClass AudioOut = new("media.audio.out");
    public static readonly MediaStreamClass AudioIn = new("media.audio.in");

    // Phase 5 — bidirectional video.
    public static readonly MediaStreamClass VideoOut = new("media.video.out");
    public static readonly MediaStreamClass VideoIn = new("media.video.in");

    // Phase 3+ — RTCP-style control.
    public static readonly MediaStreamClass Control = new("media.control");
    public static readonly MediaStreamClass Classify = new("media.classify");

    // Phase 8+ — Computer Use control plane.
    public static readonly MediaStreamClass ControlSurfaceFrame = new("control.surface.frame");
    public static readonly MediaStreamClass ControlActionLog = new("control.action.log");
    public static readonly MediaStreamClass ControlInput = new("control.input");
    public static readonly MediaStreamClass ControlApproval = new("control.approval");

    /// <summary>
    /// Top-level capability bucket the receiver should consult, mapping each
    /// class onto one of the four feature areas so quota gates charge the right
    /// counter. <c>null</c> for classes that carry no feature charge.
    /// </summary>
    public MediaFeature? Feature
    {
        get
        {
            var raw = RawValue;
            if (raw == BlobAdvertise.RawValue || raw == BlobFetch.RawValue || raw == Blob.RawValue)
            {
                return MediaFeature.FileTransfer;
            }

            if (raw == ScreenVideo.RawValue)
            {
                return MediaFeature.ScreenShare;
            }

            if (raw == VideoOut.RawValue || raw == VideoIn.RawValue || raw == AudioOut.RawValue || raw == AudioIn.RawValue)
            {
                return MediaFeature.VideoCall;
            }

            if (raw == ControlSurfaceFrame.RawValue || raw == ControlActionLog.RawValue
                || raw == ControlInput.RawValue || raw == ControlApproval.RawValue)
            {
                return MediaFeature.ComputerUse;
            }

            return null;
        }
    }

    /// <summary>
    /// Whether this class is rolled out as of the given phase number (parity:
    /// isAvailable(asOfPhase:)). Receivers refuse a too-new stream from a
    /// pre-rollout peer instead of wasting compute on an unsupported pipeline.
    /// </summary>
    public bool IsAvailable(int asOfPhase)
    {
        var raw = RawValue;
        if (raw == BlobAdvertise.RawValue || raw == BlobFetch.RawValue || raw == Blob.RawValue)
        {
            return asOfPhase >= 1;
        }

        if (raw == ScreenVideo.RawValue || raw == Control.RawValue || raw == Classify.RawValue)
        {
            return asOfPhase >= 3;
        }

        if (raw == AudioOut.RawValue || raw == AudioIn.RawValue)
        {
            return asOfPhase >= 4;
        }

        if (raw == VideoOut.RawValue || raw == VideoIn.RawValue)
        {
            return asOfPhase >= 5;
        }

        if (raw == ControlSurfaceFrame.RawValue || raw == ControlActionLog.RawValue)
        {
            return asOfPhase >= 8;
        }

        if (raw == ControlInput.RawValue || raw == ControlApproval.RawValue)
        {
            return asOfPhase >= 12;
        }

        return false;
    }

    public bool Equals(MediaStreamClass other) =>
        string.Equals(RawValue, other.RawValue, StringComparison.Ordinal);

    public override bool Equals(object? obj) => obj is MediaStreamClass other && Equals(other);

    public override int GetHashCode() => RawValue?.GetHashCode(StringComparison.Ordinal) ?? 0;

    public override string ToString() => RawValue;
}

/// <summary>Feature buckets the quota gate charges (parity: MediaStreamClass.Feature).</summary>
public enum MediaFeature
{
    FileTransfer,
    ScreenShare,
    VideoCall,
    ComputerUse,
}
