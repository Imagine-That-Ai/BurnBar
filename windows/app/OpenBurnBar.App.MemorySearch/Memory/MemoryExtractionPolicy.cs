using System;

namespace OpenBurnBar.App.MemorySearch.Memory;

// PORTED (faithful) from AgentLens/Services/Memory/MemoryExtractionPolicy.swift.
//
// Hard ceilings + clamps for the memory-extraction scheduler. All values are conservative:
// extraction is a background, best-effort enrichment. Durable writes require BOTH the consent/
// toggle/fleet gate (the kill switch here) AND authority-writes-go-live — the worker's authority
// closure is `killSwitch.IsAllowed() && authorityWritesGoLive`. There is NO min-length, dedupe,
// category filter, or confidence THRESHOLD in the policy — the only per-candidate filters live in
// the parser (non-empty, kind fallback, confidence clamp, 1000-char cap) and the secret/PII gate.

/// <summary>Hard ceilings + clamps. Swift: <c>enum MemoryExtractionPolicy</c>.</summary>
public static class MemoryExtractionPolicy
{
    /// <summary>Upper bound on transcript characters per job. Swift: <c>maxPromptChars = 16_000</c>.</summary>
    public const int MaxPromptChars = 16_000;

    /// <summary>Upper bound on model output tokens. Swift: <c>maxOutputTokens = 512</c>.</summary>
    public const int MaxOutputTokens = 512;

    /// <summary>Candidates persisted per job. Swift: <c>maxCandidatesPerJob = 12</c>.</summary>
    public const int MaxCandidatesPerJob = 12;

    /// <summary>Jobs a single foreground drain processes. Swift: <c>maxJobsPerPump = 8</c>.</summary>
    public const int MaxJobsPerPump = 8;

    /// <summary>Seconds before a bounded pump schedules its follow-up. Swift: <c>continuationDelay = 1</c>.</summary>
    public const double ContinuationDelaySeconds = 1;

    /// <summary>Per-pump wall-clock deadline (seconds). Swift: <c>maxPumpDuration = 4 * 60</c>.</summary>
    public const double MaxPumpDurationSeconds = 4 * 60;

    /// <summary>Reserved daily USD cap (local-only v1 never sends). Swift: <c>defaultDailyCapUSD = 0.50</c>.</summary>
    public const double DefaultDailyCapUsd = 0.50;

    /// <summary>Default per-request timeout (seconds). Swift: <c>defaultRequestTimeoutSeconds = 60</c>.</summary>
    public const double DefaultRequestTimeoutSeconds = 60;

    /// <summary>Clamp a configured prompt-char budget into [4000, 16000]. Swift: <c>clampedPromptChars</c>.</summary>
    public static int ClampedPromptChars(int configured) => Math.Min(Math.Max(configured, 4_000), MaxPromptChars);

    /// <summary>Clamp a configured output-token budget into [120, 512]. Swift: <c>clampedOutputTokens</c>.</summary>
    public static int ClampedOutputTokens(int configured) => Math.Min(Math.Max(configured, 120), MaxOutputTokens);
}

/// <summary>
/// Fleet kill / consent gate. Swift: <c>final class MemoryExtractionKillSwitch</c>. Lock-guarded
/// bool, seeded fail-safe (default <c>false</c>), never cached. Both extraction pumps and durable
/// writes re-read this.
/// </summary>
public sealed class MemoryExtractionKillSwitch
{
    private readonly object _gate = new();
    private bool _allowed;

    public MemoryExtractionKillSwitch(bool initiallyAllowed = false)
    {
        _allowed = initiallyAllowed;
    }

    /// <summary>Push a new gate value. Swift: <c>set(_:)</c>.</summary>
    public void Set(bool allowed)
    {
        lock (_gate)
        {
            _allowed = allowed;
        }
    }

    /// <summary>Read the current gate value. Swift: <c>isAllowed()</c>.</summary>
    public bool IsAllowed()
    {
        lock (_gate)
        {
            return _allowed;
        }
    }
}

/// <summary>
/// Thread-safe holder for the latest settings snapshot. Swift:
/// <c>final class MemoryExtractionSettingsBox</c>.
/// </summary>
public sealed class MemoryExtractionSettingsBox
{
    private readonly object _gate = new();
    private MemoryExtractionSettingsSnapshot? _current;

    public MemoryExtractionSettingsBox(MemoryExtractionSettingsSnapshot? initial = null)
    {
        _current = initial;
    }

    /// <summary>Store the latest snapshot. Swift: <c>set(_:)</c>.</summary>
    public void Set(MemoryExtractionSettingsSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        lock (_gate)
        {
            _current = snapshot;
        }
    }

    /// <summary>Read the latest snapshot (may be null before first set). Swift: <c>current</c>.</summary>
    public MemoryExtractionSettingsSnapshot? Current
    {
        get
        {
            lock (_gate)
            {
                return _current;
            }
        }
    }
}
