// The credential gate shared by the data-gated tabs (Account, Cloud, Devices & Sync).
//
// This mirrors the shape of the real Windows OAuth seam that landed in #1304 —
// OpenBurnBar.App.CloudSync.DesktopOAuthCredentialsProvider (IsSignedIn / SignedInUid) +
// FirebaseOAuthSession (Uid / Email) — WITHOUT taking a hard reference on the whole
// CloudSync/AppCheck stack. The WinUI host adapts the real provider to this interface;
// tests drive a FakeAccountSessionGate with an arbitrary signed-in state.

namespace OpenBurnBar.App.Settings.ViewModels;

/// <summary>Read-only view of the current sign-in state (adapts #1304's OAuth provider).</summary>
public interface IAccountSessionGate
{
    /// <summary>Whether a non-expired session is present (maps to <c>DesktopOAuthCredentialsProvider.IsSignedIn</c>).</summary>
    bool IsSignedIn { get; }

    /// <summary>Whether the signed-in user is anonymous (not linked to a real provider).</summary>
    bool IsAnonymous { get; }

    /// <summary>The signed-in Firebase uid, if any (maps to <c>SignedInUid</c>).</summary>
    string? SignedInUid { get; }

    /// <summary>The signed-in email, if any (maps to <c>FirebaseOAuthSession.Email</c>).</summary>
    string? SignedInEmail { get; }
}

/// <summary>A settable sign-in state for tests + the default headless (signed-out) gate.</summary>
public sealed class FakeAccountSessionGate : IAccountSessionGate
{
    /// <summary>Shared signed-out instance.</summary>
    public static readonly FakeAccountSessionGate SignedOut = new();

    /// <summary>Build a signed-in fake gate.</summary>
    public static FakeAccountSessionGate SignedInAs(string uid, string? email = null, bool anonymous = false) =>
        new() { IsSignedIn = true, SignedInUid = uid, SignedInEmail = email, IsAnonymous = anonymous };

    /// <inheritdoc />
    public bool IsSignedIn { get; set; }

    /// <inheritdoc />
    public bool IsAnonymous { get; set; }

    /// <inheritdoc />
    public string? SignedInUid { get; set; }

    /// <inheritdoc />
    public string? SignedInEmail { get; set; }
}
