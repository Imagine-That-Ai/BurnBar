using OpenBurnBar.CloudSync.AppCheck.Mint;
using OpenBurnBar.CloudSync.AppCheck.Token;

namespace OpenBurnBar.CloudSync.AppCheck.Provider;

/// <summary>
/// The outbound App Check header. Casing matches the macOS/iOS clients
/// (<c>X-Firebase-AppCheck</c>); the Hermes relay and callables read it
/// case-insensitively (<c>x-firebase-appcheck</c>), so this attaches cleanly to
/// the same server gate.
/// </summary>
public static class AppCheckHeader
{
    public const string Name = "X-Firebase-AppCheck";
}

/// <summary>Whether an outbound request may proceed with an App Check header.</summary>
public enum AppCheckDecisionKind
{
    /// <summary>A valid token was attached; the request may proceed.</summary>
    Attached,

    /// <summary>
    /// No valid token could be obtained; the header was NOT attached and the
    /// request MUST NOT proceed. This is the fail-closed outcome.
    /// </summary>
    Blocked,
}

/// <summary>
/// The result of asking the provider to authorize an outbound request. On
/// <see cref="AppCheckDecisionKind.Blocked"/> the caller must abort the request:
/// the whole point of App Check is that an un-attested client cannot reach the
/// gated backend.
/// </summary>
public sealed record AppCheckDecision
{
    public required AppCheckDecisionKind Kind { get; init; }

    /// <summary>The attached token (present only when <see cref="Kind"/> is Attached).</summary>
    public AppCheckToken? Token { get; init; }

    /// <summary>Why the request was blocked (present only when <see cref="Kind"/> is Blocked).</summary>
    public AppCheckMintFailure? Failure { get; init; }

    /// <summary>Human-readable reason for a block (for logs/telemetry).</summary>
    public string? BlockReason { get; init; }

    public bool IsAttached => Kind == AppCheckDecisionKind.Attached;
    public bool IsBlocked => Kind == AppCheckDecisionKind.Blocked;

    public static AppCheckDecision Attach(AppCheckToken token) =>
        new() { Kind = AppCheckDecisionKind.Attached, Token = token };

    public static AppCheckDecision Block(AppCheckMintFailure failure, string reason) =>
        new() { Kind = AppCheckDecisionKind.Blocked, Failure = failure, BlockReason = reason };
}
