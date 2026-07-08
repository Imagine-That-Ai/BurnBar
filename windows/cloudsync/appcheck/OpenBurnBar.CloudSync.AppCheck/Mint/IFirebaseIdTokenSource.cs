using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.CloudSync.AppCheck.Mint;

/// <summary>
/// Supplies the caller's Firebase Auth ID token for the <c>Authorization: Bearer</c>
/// header on the mint call. The mint callable requires an authenticated user
/// (<c>request.auth.uid</c>) and is rate-limited per-uid, so a signed-in ID token
/// is mandatory. A source that has no token (signed-out) returns null, which the
/// mint client turns into a fail-closed <see cref="AppCheckMintFailure.MissingIdToken"/>.
/// </summary>
public interface IFirebaseIdTokenSource
{
    /// <summary>Return a current Firebase ID token, or null when signed out.</summary>
    ValueTask<string?> GetIdTokenAsync(CancellationToken cancellationToken = default);
}
