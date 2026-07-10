using System;
using OpenBurnBar.App.Settings.ViewModels;
using OpenBurnBar.ComputerUse.Core.Gate;
using Xunit;

namespace OpenBurnBar.App.Settings.ViewModels.Tests;

public sealed class ComputerUseSettingsViewModelTests
{
    private sealed class FailingAuditService : IComputerUseAuditService
    {
        public AuditActionResult ValidateChain(string sessionId) => AuditActionResult.Fail("hash mismatch");

        public AuditActionResult ExportArchive(string sessionId, bool includeScreenshots) => AuditActionResult.Fail("io error");

        public AuditActionResult Notarize(string sessionId) => AuditActionResult.Fail("ots down");
    }

    private sealed class RecordingSessionService(bool succeeds = true) : IComputerUseSessionService
    {
        public bool SupportsNonBypassableInput => true;

        public int Starts { get; private set; }
        public int Ends { get; private set; }
        public ComputerUseTrustMode? TrustMode { get; private set; }

        public ComputerUseSessionStartResult StartSession(ComputerUseTrustMode trustMode, DateTimeOffset startedAt)
        {
            Starts++;
            TrustMode = trustMode;
            return succeeds
                ? ComputerUseSessionStartResult.Started("windows-session-1")
                : ComputerUseSessionStartResult.Fail("host unavailable");
        }

        public void EndSession() => Ends++;
    }

    [Fact]
    public void Defaults_MatchTheSwiftSurface()
    {
        var vm = new ComputerUseSettingsViewModel();
        Assert.Equal(ComputerUseSettingsSection.Setup, vm.Section);
        Assert.False(vm.AccessibilityTrusted);
        Assert.Equal(ComputerUseTrustMode.Manual, vm.LiveTrustMode);
        Assert.True(vm.AuditIncludeScreenshots);
        Assert.False(vm.AuditNotarizationOptIn);
        Assert.Equal(AuditOperationKind.Idle, vm.AuditStatus.Kind);
    }

    [Fact]
    public void RefreshReadiness_ReadsTheAccessibilityProbe()
    {
        var probe = new StaticAccessibilityProbe(false);
        var vm = new ComputerUseSettingsViewModel(probe);
        Assert.False(vm.IsReady);

        probe.IsAccessibilityTrusted = true;
        vm.RefreshReadiness();
        Assert.True(vm.IsReady);
    }

    [Fact]
    public void TrustModeChoices_ComeFromTheCoreEnum()
    {
        var vm = new ComputerUseSettingsViewModel();
        Assert.Contains(ComputerUseTrustMode.Manual, vm.TrustModeChoices);
        Assert.Contains(ComputerUseTrustMode.Step, vm.TrustModeChoices);
        Assert.Contains(ComputerUseTrustMode.Trusted, vm.TrustModeChoices);
        Assert.Equal(3, vm.ModeChoices.Count);
    }

    [Fact]
    public void BuiltInDenyRules_AreExposedFromTheCore()
    {
        var vm = new ComputerUseSettingsViewModel();
        Assert.NotEmpty(vm.BuiltInDenyRules);
    }

    [Fact]
    public void AuditActions_DisabledWithoutASessionId()
    {
        var vm = new ComputerUseSettingsViewModel();
        Assert.False(vm.CanValidateChain);
        Assert.False(vm.CanExportArchive);
        Assert.False(vm.CanNotarize);

        vm.AuditSessionId = "  session-42  ";
        Assert.Equal("session-42", vm.TrimmedAuditSessionId);
        Assert.True(vm.CanValidateChain);
        Assert.True(vm.CanExportArchive);
    }

    [Fact]
    public void Notarize_AlsoRequiresTheOptIn()
    {
        var vm = new ComputerUseSettingsViewModel { AuditSessionId = "s1" };
        Assert.False(vm.CanNotarize);
        vm.AuditNotarizationOptIn = true;
        Assert.True(vm.CanNotarize);
    }

    [Fact]
    public void ValidateChain_SetsSucceededOnSuccess()
    {
        var vm = new ComputerUseSettingsViewModel(audit: new NoopComputerUseAuditService()) { AuditSessionId = "s1" };
        vm.ValidateChain();
        Assert.Equal(AuditOperationKind.Succeeded, vm.AuditStatus.Kind);
    }

    [Fact]
    public void ExportArchive_SetsFailedOnFailure()
    {
        var vm = new ComputerUseSettingsViewModel(audit: new FailingAuditService()) { AuditSessionId = "s1" };
        vm.ExportArchive();
        Assert.Equal(AuditOperationKind.Failed, vm.AuditStatus.Kind);
        Assert.Equal("io error", vm.AuditStatus.Message);
    }

    [Fact]
    public void StartSession_RecordsTheInjectedClock()
    {
        var when = new DateTimeOffset(2026, 7, 6, 12, 0, 0, TimeSpan.Zero);
        var session = new RecordingSessionService();
        var vm = new ComputerUseSettingsViewModel(session: session, now: () => when)
        {
            LiveTrustMode = ComputerUseTrustMode.Step,
        };
        vm.StartSession();
        Assert.True(vm.IsSessionActive);
        Assert.Equal(when, vm.SessionStartedAt);
        Assert.Equal("windows-session-1", vm.ActiveSessionId);
        Assert.Equal(ComputerUseTrustMode.Step, session.TrustMode);

        vm.EndSession();
        Assert.False(vm.IsSessionActive);
        Assert.Null(vm.SessionStartedAt);
        Assert.Null(vm.ActiveSessionId);
        Assert.Equal(1, session.Ends);
    }

    [Fact]
    public void StartSession_DoesNotShowActiveWhenPlatformHostFails()
    {
        var session = new RecordingSessionService(succeeds: false);
        var vm = new ComputerUseSettingsViewModel(session: session);

        vm.StartSession();

        Assert.False(vm.IsSessionActive);
        Assert.Null(vm.ActiveSessionId);
        Assert.Equal("host unavailable", vm.SessionStatusMessage);
    }

    [Fact]
    public void CompletePermissionsSetup_RecordsOnboardingFlag()
    {
        var store = new InMemoryComputerUsePermissionsStore();
        var vm = new ComputerUseSettingsViewModel(permissions: store);
        Assert.False(vm.PermissionsOnboardingCompleted);
        vm.CompletePermissionsSetup();
        Assert.True(vm.PermissionsOnboardingCompleted);
        Assert.True(store.OnboardingCompleted);
    }
}
