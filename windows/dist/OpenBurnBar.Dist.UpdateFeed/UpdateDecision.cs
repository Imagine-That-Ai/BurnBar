// The fail-closed update decision (Phase 5 · signed distribution).
//
// Ties the pieces together: given the installed version + host facts and a feed document, decide
// whether an AUTHENTICATED, ELIGIBLE, strictly-newer release is available. The security-critical
// invariant: an entry that is not authentic under the pinned key can NEVER produce
// UpdateAvailability.Available — it is dropped before any version/eligibility comparison. This is
// the C# analog of Sparkle's "reject the appcast item unless its EdDSA signature validates".

using System;
using System.Collections.Generic;

namespace OpenBurnBar.Dist.UpdateFeed;

/// <summary>The outcome of evaluating a feed against the installed build.</summary>
public enum UpdateAvailability
{
    /// <summary>No authenticated entry is newer than what is installed.</summary>
    UpToDate,

    /// <summary>An authenticated, eligible, strictly-newer release is available to install.</summary>
    Available,

    /// <summary>An authenticated newer release exists but requires a newer Windows build.</summary>
    BlockedByOsFloor,
}

/// <summary>Host facts the decision needs. Immutable.</summary>
public sealed record UpdateHostContext
{
    /// <summary>The installed app version (parsed strictly; an unparseable value fails closed).</summary>
    public required string InstalledVersion { get; init; }

    /// <summary>The host architecture — only matching-platform entries are eligible.</summary>
    public required UpdatePlatform Platform { get; init; }

    /// <summary>The channel the user is subscribed to (Stable users never see Beta).</summary>
    public UpdateChannel Channel { get; init; } = UpdateChannel.Stable;

    /// <summary>The host Windows build number (e.g. 22631). Entries with a higher minOsBuild are blocked.</summary>
    public required int OsBuild { get; init; }
}

/// <summary>The result of a decision — the availability plus the chosen verified entry (if any).</summary>
public sealed class UpdateDecisionResult
{
    private UpdateDecisionResult(UpdateAvailability availability, UpdateFeedEntry? entry)
    {
        Availability = availability;
        Entry = entry;
    }

    /// <summary>The availability verdict.</summary>
    public UpdateAvailability Availability { get; }

    /// <summary>The winning authenticated entry (present for Available / BlockedByOsFloor).</summary>
    public UpdateFeedEntry? Entry { get; }

    internal static UpdateDecisionResult UpToDate() => new(UpdateAvailability.UpToDate, null);

    internal static UpdateDecisionResult Available(UpdateFeedEntry entry) => new(UpdateAvailability.Available, entry);

    internal static UpdateDecisionResult BlockedByOsFloor(UpdateFeedEntry entry) => new(UpdateAvailability.BlockedByOsFloor, entry);
}

/// <summary>Evaluates a feed against the host, verifying every entry under the pinned key first.</summary>
public sealed class UpdateDecisionEngine
{
    private readonly Ed25519UpdateFeedVerifier _verifier;

    /// <summary>Create an engine bound to a pinned-key verifier.</summary>
    public UpdateDecisionEngine(Ed25519UpdateFeedVerifier verifier)
    {
        _verifier = verifier ?? throw new ArgumentNullException(nameof(verifier));
    }

    /// <summary>
    /// Decide the best available update. Steps, in order (each a hard gate):
    ///   1. Drop the entry unless its pinned Ed25519 signature verifies (fail-closed).
    ///   2. Drop the entry unless its platform matches the host.
    ///   3. Drop the entry unless its channel is eligible for the host's channel
    ///      (Stable host: Stable only; Beta host: Stable or Beta).
    ///   4. Drop the entry unless it is strictly newer than the installed version.
    ///   5. Among the survivors, pick the highest version. If that entry's minimum OS build is
    ///      above the host build, report BlockedByOsFloor; otherwise Available.
    /// An unparseable installed version fails closed to UpToDate (never offers).
    /// </summary>
    public UpdateDecisionResult Decide(UpdateHostContext host, IReadOnlyList<UpdateFeedEntry> entries)
    {
        ArgumentNullException.ThrowIfNull(host);
        ArgumentNullException.ThrowIfNull(entries);

        if (!UpdateVersion.TryParse(host.InstalledVersion, out var installed) || installed is null)
        {
            // A build that cannot parse its own version must not offer/instal anything.
            return UpdateDecisionResult.UpToDate();
        }

        UpdateFeedEntry? best = null;
        UpdateVersion? bestVersion = null;

        foreach (var entry in entries)
        {
            // 1. Authenticity gate — the ONLY gate that matters for security.
            var verification = _verifier.VerifyDescriptor(entry);
            if (!verification.IsAuthentic)
            {
                continue;
            }

            // 2. Platform gate.
            if (entry.Platform != host.Platform)
            {
                continue;
            }

            // 3. Channel eligibility gate.
            if (!IsChannelEligible(host.Channel, entry.Channel))
            {
                continue;
            }

            // 4. Strictly-newer gate.
            if (!UpdateVersion.TryParse(entry.Version, out var candidate) || candidate is null)
            {
                continue;
            }

            if (!UpdateVersion.IsNewer(candidate, installed))
            {
                continue;
            }

            // 5. Track the highest survivor.
            if (bestVersion is null || candidate.CompareTo(bestVersion) > 0)
            {
                best = entry;
                bestVersion = candidate;
            }
        }

        if (best is null)
        {
            return UpdateDecisionResult.UpToDate();
        }

        if (best.MinimumOsBuild > host.OsBuild)
        {
            return UpdateDecisionResult.BlockedByOsFloor(best);
        }

        return UpdateDecisionResult.Available(best);
    }

    private static bool IsChannelEligible(UpdateChannel hostChannel, UpdateChannel entryChannel) => hostChannel switch
    {
        UpdateChannel.Stable => entryChannel == UpdateChannel.Stable,
        UpdateChannel.Beta => entryChannel is UpdateChannel.Stable or UpdateChannel.Beta,
        _ => false,
    };
}
