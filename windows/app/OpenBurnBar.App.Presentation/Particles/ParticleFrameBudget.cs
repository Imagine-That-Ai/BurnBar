using System;

namespace OpenBurnBar.App.Presentation.Particles;

/// <summary>
/// Portable 60fps frame budget meter (production path for particle substrate timing).
/// GPU draw remains Win2D host; timing policy is testable off-device.
/// </summary>
public static class ParticleFrameBudget
{
    public const double TargetFps = 60.0;

    public static TimeSpan TargetFrameDuration { get; } = TimeSpan.FromSeconds(1.0 / TargetFps);

    /// <summary>
    /// Given a measured frame duration, return whether it meets the 60fps budget
    /// and the achieved fps estimate.
    /// </summary>
    public static ParticleFrameSample Evaluate(TimeSpan frameDuration)
    {
        if (frameDuration <= TimeSpan.Zero)
        {
            return new ParticleFrameSample(0, MeetsBudget: false);
        }

        double fps = 1.0 / frameDuration.TotalSeconds;
        bool meets = frameDuration <= TargetFrameDuration * 1.05; // 5% tolerance
        return new ParticleFrameSample(fps, meets);
    }

    /// <summary>
    /// Simulate N frames at a fixed step duration (unit-testable production policy).
    /// </summary>
    public static ParticleFrameReport Simulate(int frames, TimeSpan step)
    {
        if (frames <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(frames));
        }

        int ok = 0;
        double sumFps = 0;
        for (int i = 0; i < frames; i++)
        {
            ParticleFrameSample sample = Evaluate(step);
            sumFps += sample.Fps;
            if (sample.MeetsBudget)
            {
                ok++;
            }
        }

        return new ParticleFrameReport(frames, ok, sumFps / frames, TargetFps);
    }
}

public sealed record ParticleFrameSample(double Fps, bool MeetsBudget);

public sealed record ParticleFrameReport(int Frames, int FramesOnBudget, double AverageFps, double TargetFps);
