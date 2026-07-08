using OpenBurnBar.App.Settings.ViewModels;
using Xunit;

namespace OpenBurnBar.App.Settings.ViewModels.Tests;

/// <summary>
/// Account / Cloud / Devices &amp; Sync are data-gated: their live session comes from the
/// #1304 OAuth credential gate. These tests drive a fake signed-in state.
/// </summary>
public sealed class DataGatedSettingsViewModelTests
{
    private sealed class FailingAccountHost : IAccountActionHost
    {
        public AccountActionResult SignInWithEmail(string email, string password) => AccountActionResult.Fail("bad creds");

        public AccountActionResult SignUpWithEmail(string email, string password) => AccountActionResult.Ok;

        public AccountActionResult LinkProvider(AuthProviderAction provider) => AccountActionResult.Ok;

        public AccountActionResult UpgradeToPremium() => AccountActionResult.Ok;

        public AccountActionResult DeleteAccount() => AccountActionResult.Ok;

        public AccountActionResult SignOut() => AccountActionResult.Ok;
    }

    // ── Account ───────────────────────────────────────────────────────────────

    [Fact]
    public void Account_ReflectsInjectedSignedInState()
    {
        var vm = new AccountSettingsViewModel(FakeAccountSessionGate.SignedInAs("uid-1", "a@b.com"));
        Assert.True(vm.IsSignedIn);
        Assert.Equal("a@b.com", vm.SignedInEmail);
        Assert.Equal("a@b.com", vm.IdentityLine);
    }

    [Fact]
    public void Account_SignedOutByDefault()
    {
        var vm = new AccountSettingsViewModel();
        Assert.False(vm.IsSignedIn);
        Assert.Equal("Not signed in", vm.IdentityLine);
    }

    [Fact]
    public void Account_EmailFormRequiresBothFields()
    {
        var vm = new AccountSettingsViewModel();
        Assert.False(vm.CanSubmitEmail);
        vm.EmailDraft = "a@b.com";
        Assert.False(vm.CanSubmitEmail);
        vm.PasswordDraft = "pw";
        Assert.True(vm.CanSubmitEmail);
    }

    [Fact]
    public void Account_SubmitEmail_SurfacesHostError()
    {
        var vm = new AccountSettingsViewModel(host: new FailingAccountHost())
        {
            EmailDraft = "a@b.com",
            PasswordDraft = "pw",
        };
        Assert.False(vm.SubmitEmail());
        Assert.True(vm.HasAuthError);
        Assert.Equal("bad creds", vm.AuthError);
    }

    [Fact]
    public void Account_DeleteRequiresConfirmationFirst()
    {
        var vm = new AccountSettingsViewModel(host: new NoopAccountActionHost());
        Assert.False(vm.DeleteAccount()); // no confirmation
        vm.ShowDeleteConfirmation = true;
        Assert.True(vm.DeleteAccount());
        Assert.False(vm.ShowDeleteConfirmation); // reset after
    }

    // ── Cloud ─────────────────────────────────────────────────────────────────

    [Fact]
    public void Cloud_Defaults_AllBackupOff()
    {
        var vm = new CloudSettingsViewModel();
        Assert.False(vm.ConversationBackupEnabled);
        Assert.False(vm.ShowSubToggles);
        Assert.False(vm.SessionLogConsentShown);
    }

    [Fact]
    public void Cloud_EnablingBackup_ShowsConsentAndSubToggles()
    {
        var vm = new CloudSettingsViewModel();
        vm.ConversationBackupEnabled = true;
        Assert.True(vm.ShowSubToggles);
        Assert.True(vm.SessionLogConsentShown);
    }

    [Fact]
    public void Cloud_EnablingChatThreadBackup_ShowsItsConsent()
    {
        var vm = new CloudSettingsViewModel();
        vm.ChatThreadBackupEnabled = true;
        Assert.True(vm.ChatThreadConsentShown);
    }

    [Fact]
    public void Cloud_BackupNowGatedOnSignInAndEnabled()
    {
        var signedOut = new CloudSettingsViewModel(session: FakeAccountSessionGate.SignedOut);
        signedOut.ConversationBackupEnabled = true;
        Assert.False(signedOut.CanTriggerBackup);
        Assert.False(signedOut.TriggerBackup());

        var host = new RecordingCloudBackupHost();
        var signedIn = new CloudSettingsViewModel(
            session: FakeAccountSessionGate.SignedInAs("uid-1"), backupHost: host);
        signedIn.ConversationBackupEnabled = true;
        Assert.True(signedIn.CanTriggerBackup);
        Assert.True(signedIn.TriggerBackup());
        Assert.Equal(1, host.TriggerCount);
    }

    // ── Devices & Sync ────────────────────────────────────────────────────────

    [Fact]
    public void Devices_ManagementGatedOnSignIn()
    {
        var signedOut = new DevicesAndSyncSettingsViewModel(session: FakeAccountSessionGate.SignedOut);
        Assert.False(signedOut.CanManageDevices);
        Assert.False(signedOut.BeginApproval("d1"));
    }

    [Fact]
    public void Devices_ApprovalRequiresSafetyCompare()
    {
        var host = new InMemoryDeviceTrustHost(new[]
        {
            new TrustedDeviceInfo("d1", "iPhone", "iOS", false),
        });
        var vm = new DevicesAndSyncSettingsViewModel(
            host, session: FakeAccountSessionGate.SignedInAs("uid-1"));

        Assert.True(vm.BeginApproval("d1"));
        Assert.True(vm.IsAwaitingApproval);
        Assert.False(vm.CanApprovePendingDevice); // compare not confirmed
        Assert.False(vm.ApprovePendingDevice());

        vm.ConfirmSafetyCompare();
        Assert.True(vm.CanApprovePendingDevice);
        Assert.True(vm.ApprovePendingDevice());
        Assert.False(vm.IsAwaitingApproval);
    }

    [Fact]
    public void Devices_RevokeRemovesDevice()
    {
        var host = new InMemoryDeviceTrustHost(new[]
        {
            new TrustedDeviceInfo("d1", "iPad", "iOS", true),
        });
        var vm = new DevicesAndSyncSettingsViewModel(
            host, session: FakeAccountSessionGate.SignedInAs("uid-1"));
        Assert.Equal(1, vm.DeviceCount);
        Assert.True(vm.Revoke("d1"));
        Assert.Equal(0, vm.DeviceCount);
    }

    [Fact]
    public void Devices_CloudSyncTogglePersists()
    {
        var store = new InMemoryDevicesSyncStore();
        var vm = new DevicesAndSyncSettingsViewModel(store: store);
        vm.CloudSyncEnabled = true;
        Assert.True(store.CloudSyncEnabled);
    }
}
