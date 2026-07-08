// View-model for the Account settings tab.
//
// Faithful port of AgentLens/Views/Settings/AccountSettingsView.swift — an auth surface
// with NO persisted UserDefaults: it reads the injected session (via IAccountSessionGate,
// backed by #1304's DesktopOAuthCredentialsProvider on Windows) and drives sign-in /
// link / upgrade / delete / sign-out commands (IAccountActionHost).
//
// Data-gated: the live session comes from OAuth (#1304, Wave 2). Tests wire a fake
// signed-in state. Validation mirrors the Swift view: the email form submit is enabled
// only when both email and password are non-empty (no format/length check).

using System;

namespace OpenBurnBar.App.Settings.ViewModels;

/// <summary>Email sub-form mode (Swift <c>EmailAuthMode</c>).</summary>
public enum EmailAuthMode
{
    SignIn,
    SignUp,
}

/// <summary>Auth provider a link/sign-in action targets (Swift <c>AuthProviderAction</c>).</summary>
public enum AuthProviderAction
{
    Apple,
    Google,
    GitHub,
    Email,
}

/// <summary>Result of an account command (success + optional error message).</summary>
public sealed record AccountActionResult(bool Success, string? Error)
{
    public static readonly AccountActionResult Ok = new(true, null);

    public static AccountActionResult Fail(string error) => new(false, error);
}

/// <summary>Runs the account commands (sign-in / link / upgrade / delete / sign-out). Data/OS-bound.</summary>
public interface IAccountActionHost
{
    AccountActionResult SignInWithEmail(string email, string password);

    AccountActionResult SignUpWithEmail(string email, string password);

    AccountActionResult LinkProvider(AuthProviderAction provider);

    AccountActionResult UpgradeToPremium();

    AccountActionResult DeleteAccount();

    AccountActionResult SignOut();
}

/// <summary>A deterministic account host that always succeeds (default for tests).</summary>
public sealed class NoopAccountActionHost : IAccountActionHost
{
    public AccountActionResult SignInWithEmail(string email, string password) => AccountActionResult.Ok;

    public AccountActionResult SignUpWithEmail(string email, string password) => AccountActionResult.Ok;

    public AccountActionResult LinkProvider(AuthProviderAction provider) => AccountActionResult.Ok;

    public AccountActionResult UpgradeToPremium() => AccountActionResult.Ok;

    public AccountActionResult DeleteAccount() => AccountActionResult.Ok;

    public AccountActionResult SignOut() => AccountActionResult.Ok;
}

/// <summary>Backs the Account tab (sign-in, subscription, account actions).</summary>
public sealed class AccountSettingsViewModel : ObservableSettingsViewModel
{
    private readonly IAccountSessionGate _session;
    private readonly IAccountActionHost _host;

    private EmailAuthMode _emailMode = EmailAuthMode.SignIn;
    private string _emailDraft = string.Empty;
    private string _passwordDraft = string.Empty;
    private string? _authError;
    private bool _showDeleteConfirmation;
    private bool _isDeletingAccount;

    public AccountSettingsViewModel(
        IAccountSessionGate? session = null,
        IAccountActionHost? host = null)
    {
        _session = session ?? FakeAccountSessionGate.SignedOut;
        _host = host ?? new NoopAccountActionHost();
    }

    /// <summary>Whether a user is signed in.</summary>
    public bool IsSignedIn => _session.IsSignedIn;

    /// <summary>Whether the signed-in user is anonymous.</summary>
    public bool IsAnonymous => _session.IsAnonymous;

    /// <summary>The signed-in email (or null).</summary>
    public string? SignedInEmail => _session.SignedInEmail;

    /// <summary>The signed-in uid (or null).</summary>
    public string? SignedInUid => _session.SignedInUid;

    /// <summary>A friendly identity line for the header.</summary>
    public string IdentityLine => IsSignedIn
        ? (SignedInEmail ?? SignedInUid ?? "Signed in")
        : "Not signed in";

    /// <summary>The email sub-form mode (sign in vs sign up).</summary>
    public EmailAuthMode EmailMode
    {
        get => _emailMode;
        set => Set(ref _emailMode, value);
    }

    /// <summary>Email draft.</summary>
    public string EmailDraft
    {
        get => _emailDraft;
        set { if (Set(ref _emailDraft, value ?? string.Empty)) { OnPropertyChanged(nameof(CanSubmitEmail)); } }
    }

    /// <summary>Password draft.</summary>
    public string PasswordDraft
    {
        get => _passwordDraft;
        set { if (Set(ref _passwordDraft, value ?? string.Empty)) { OnPropertyChanged(nameof(CanSubmitEmail)); } }
    }

    /// <summary>Whether the email form can submit (both fields non-empty; Swift <c>.disabled(email||password empty)</c>).</summary>
    public bool CanSubmitEmail =>
        !string.IsNullOrEmpty(_emailDraft) && !string.IsNullOrEmpty(_passwordDraft);

    /// <summary>The last auth error, if any.</summary>
    public string? AuthError
    {
        get => _authError;
        private set { if (Set(ref _authError, value)) { OnPropertyChanged(nameof(HasAuthError)); } }
    }

    /// <summary>Whether an auth error banner should render.</summary>
    public bool HasAuthError => _authError is not null;

    /// <summary>Whether the delete-account confirmation is showing.</summary>
    public bool ShowDeleteConfirmation
    {
        get => _showDeleteConfirmation;
        set => Set(ref _showDeleteConfirmation, value);
    }

    /// <summary>Whether an account deletion is in flight.</summary>
    public bool IsDeletingAccount
    {
        get => _isDeletingAccount;
        private set => Set(ref _isDeletingAccount, value);
    }

    /// <summary>Clear any surfaced auth error.</summary>
    public void ClearError() => AuthError = null;

    /// <summary>Submit the email form in the current mode. Returns false when the form is invalid.</summary>
    public bool SubmitEmail()
    {
        if (!CanSubmitEmail)
        {
            return false;
        }

        var result = _emailMode == EmailAuthMode.SignIn
            ? _host.SignInWithEmail(_emailDraft, _passwordDraft)
            : _host.SignUpWithEmail(_emailDraft, _passwordDraft);
        return Apply(result);
    }

    /// <summary>Link a social provider (apple/google/github).</summary>
    public bool LinkProvider(AuthProviderAction provider) => Apply(_host.LinkProvider(provider));

    /// <summary>Upgrade to the premium plan.</summary>
    public bool UpgradeToPremium() => Apply(_host.UpgradeToPremium());

    /// <summary>Sign out.</summary>
    public bool SignOut()
    {
        var result = Apply(_host.SignOut());
        RaiseSession();
        return result;
    }

    /// <summary>
    /// Delete the account. Requires the confirmation flag to be set first (Swift's alert
    /// gate) — returns false otherwise.
    /// </summary>
    public bool DeleteAccount()
    {
        if (!_showDeleteConfirmation || _isDeletingAccount)
        {
            return false;
        }

        IsDeletingAccount = true;
        var result = _host.DeleteAccount();
        IsDeletingAccount = false;
        ShowDeleteConfirmation = false;
        var applied = Apply(result);
        RaiseSession();
        return applied;
    }

    private bool Apply(AccountActionResult result)
    {
        AuthError = result.Success ? null : result.Error;
        return result.Success;
    }

    private void RaiseSession()
    {
        OnPropertyChanged(nameof(IsSignedIn));
        OnPropertyChanged(nameof(IsAnonymous));
        OnPropertyChanged(nameof(SignedInEmail));
        OnPropertyChanged(nameof(SignedInUid));
        OnPropertyChanged(nameof(IdentityLine));
    }
}
