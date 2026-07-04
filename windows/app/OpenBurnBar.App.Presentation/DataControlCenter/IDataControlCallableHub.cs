using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Memories;

namespace OpenBurnBar.App.Presentation.DataControlCenter;

// The CALLABLE HUB seam for the Data Control Center — the portable interface the view-model
// depends on, and the Firebase Functions boundary the Windows integrator implements later.
//
// Mirrors the callables driven by AgentLens/Services/DataControlCenterViewModel.swift
// (getDataDomainUsage / exportUserData / deleteDomainData / listRecovery / setupRecovery /
// confirmRecovery / revokeAllAccess / getAuditLog / verifyAuditLog). Keeping it an interface lets
// the macOS `dotnet test` drive the view-model with an in-memory fake — exactly as the Swift
// original is exercised in the app — while the real FirebaseFunctions client (Windows/dev-host-
// deferred) is a thin adapter that shapes the same typed results.

/// <summary>
/// The Firebase callable boundary the Data Control Center view-model routes every mutation
/// through. Implementations own auth, region ("us-central1"), payload shaping, and result decode.
/// </summary>
public interface IDataControlCallableHub
{
    /// <summary>Whether a real (non-anonymous) account is signed in. Gates every callable.</summary>
    bool IsSignedIn { get; }

    /// <summary>getDataDomainUsage → the live tier + Pensieve caps + per-domain count/bytes.</summary>
    Task<DataDomainUsageSnapshot> GetUsageAsync(CancellationToken cancellationToken = default);

    /// <summary>exportUserData → the pretty-printed export JSON (null domains = everything).</summary>
    Task<string> ExportAsync(IReadOnlyList<string>? domains, CancellationToken cancellationToken = default);

    /// <summary>deleteDomainData → the per-domain deletion tally.</summary>
    Task<DeleteResult> DeleteDomainAsync(string domainId, CancellationToken cancellationToken = default);

    /// <summary>listRecovery → the registered recovery methods.</summary>
    Task<IReadOnlyList<RecoveryMethod>> ListRecoveryAsync(CancellationToken cancellationToken = default);

    /// <summary>setupRecovery → the new method's recovery id.</summary>
    Task<string> SetupRecoveryAsync(
        RecoveryKind method,
        IReadOnlyDictionary<string, object?> payload,
        CancellationToken cancellationToken = default);

    /// <summary>confirmRecovery → whether the confirmation was accepted.</summary>
    Task<bool> ConfirmRecoveryAsync(
        string recoveryId,
        string? verificationHash = null,
        CancellationToken cancellationToken = default);

    /// <summary>revokeAllAccess → the panic teardown tally.</summary>
    Task<RevokeResult> RevokeAllAsync(RevokeScope scope, CancellationToken cancellationToken = default);

    /// <summary>getAuditLog → a page of tamper-evident events + the continuation cursor.</summary>
    Task<AuditPage> GetAuditLogAsync(string? cursor, int limit = 100, CancellationToken cancellationToken = default);

    /// <summary>verifyAuditLog → whether the hash chain is intact (and where it broke).</summary>
    Task<AuditVerification> VerifyAuditLogAsync(CancellationToken cancellationToken = default);
}

/// <summary>
/// A signed-out hub: every call throws <see cref="NotSignedInException"/>, and
/// <see cref="IsSignedIn"/> is false. The view-model renders the registry-seeded inventory and
/// surfaces the calm "Sign in to…" copy against this until a real hub is bound — the Windows
/// analog of the Swift <c>guard isSignedIn</c> short-circuit.
/// </summary>
public sealed class SignedOutCallableHub : IDataControlCallableHub
{
    public static SignedOutCallableHub Instance { get; } = new();

    public bool IsSignedIn => false;

    public Task<DataDomainUsageSnapshot> GetUsageAsync(CancellationToken cancellationToken = default) => throw NotSignedIn();

    public Task<string> ExportAsync(IReadOnlyList<string>? domains, CancellationToken cancellationToken = default) => throw NotSignedIn();

    public Task<DeleteResult> DeleteDomainAsync(string domainId, CancellationToken cancellationToken = default) => throw NotSignedIn();

    public Task<IReadOnlyList<RecoveryMethod>> ListRecoveryAsync(CancellationToken cancellationToken = default) => throw NotSignedIn();

    public Task<string> SetupRecoveryAsync(RecoveryKind method, IReadOnlyDictionary<string, object?> payload, CancellationToken cancellationToken = default) => throw NotSignedIn();

    public Task<bool> ConfirmRecoveryAsync(string recoveryId, string? verificationHash = null, CancellationToken cancellationToken = default) => throw NotSignedIn();

    public Task<RevokeResult> RevokeAllAsync(RevokeScope scope, CancellationToken cancellationToken = default) => throw NotSignedIn();

    public Task<AuditPage> GetAuditLogAsync(string? cursor, int limit = 100, CancellationToken cancellationToken = default) => throw NotSignedIn();

    public Task<AuditVerification> VerifyAuditLogAsync(CancellationToken cancellationToken = default) => throw NotSignedIn();

    private static NotSignedInException NotSignedIn() => new();
}

/// <summary>Thrown when a callable is attempted without a signed-in account.</summary>
public sealed class NotSignedInException : Exception, IFriendlyError
{
    public NotSignedInException()
        : base("Not signed in.")
    {
    }

    public string? FriendlyMessage => "Sign in to OpenBurnBar to manage your data.";
}

/// <summary>
/// Thrown when a callable returns a payload that cannot be decoded. Faithful analog of the Swift
/// <c>DataControlError.malformedResponse</c>.
/// </summary>
public sealed class MalformedResponseException : Exception, IFriendlyError
{
    public MalformedResponseException()
        : base("The server returned an unexpected response.")
    {
    }

    public string? FriendlyMessage => "The server returned an unexpected response.";
}
