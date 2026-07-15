using System;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Settings.ViewModels;
using OpenBurnBar.ComputerUse.Core.Browser;
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

    private sealed class BrowserService(bool available, BrowserSessionResult result) : IComputerUseBrowserService
    {
        public int Calls { get; private set; }

        public bool IsAvailable => available;

        public string RuntimeStatus => available ? "Ready" : "Missing";

        public Task<BrowserSessionResult> RunCheckAsync(string startUrl, CancellationToken cancellationToken)
        {
            Calls++;
            return Task.FromResult(result);
        }
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
        var vm = new ComputerUseSettingsViewModel(now: () => when);
        vm.StartSession();
        Assert.True(vm.IsSessionActive);
        Assert.Equal(when, vm.SessionStartedAt);

        vm.EndSession();
        Assert.False(vm.IsSessionActive);
        Assert.Null(vm.SessionStartedAt);
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

    [Fact]
    public async Task BrowserCheck_UsesProductionSeamAndPersistsTarget()
    {
        var browser = new BrowserService(
            true,
            BrowserSessionResult.Ok("session", new[] { new BrowserEvalResult("document.title", "OpenBurnBar") }));
        var settings = new InMemoryComputerUseBrowserSettingsStore();
        var vm = new ComputerUseSettingsViewModel(browserSettings: settings, browser: browser)
        {
            BrowserCheckUrl = "https://example.org/check",
        };

        await vm.RunBrowserCheck();

        Assert.Equal(1, browser.Calls);
        Assert.Equal("https://example.org/check", settings.BrowserCheckUrl);
        Assert.Equal("Browser runtime check passed.", vm.BrowserCheckStatus);
        Assert.True(vm.CanRunBrowserCheck);
    }

    [Fact]
    public async Task BrowserCheck_FailsClosedForInvalidTargetOrMissingRuntime()
    {
        var browser = new BrowserService(false, BrowserSessionResult.Fail("should_not_run"));
        var vm = new ComputerUseSettingsViewModel(browser: browser)
        {
            BrowserCheckUrl = "file:///C:/secrets.txt",
        };

        await vm.RunBrowserCheck();

        Assert.Equal(0, browser.Calls);
        Assert.Equal("Missing", vm.BrowserCheckStatus);
        Assert.False(vm.CanRunBrowserCheck);
    }

    [Theory]
    [InlineData("http://localhost/admin")]
    [InlineData("http://127.0.0.1/admin")]
    [InlineData("http://10.1.2.3/admin")]
    [InlineData("http://169.254.169.254/latest/meta-data")]
    [InlineData("http://[::1]/admin")]
    [InlineData("https://user:password@example.com")]
    public async Task BrowserCheck_RejectsKnownInternalAndCredentialTargetsBeforeLaunch(string target)
    {
        var browser = new BrowserService(
            true,
            BrowserSessionResult.Ok("unexpected", Array.Empty<BrowserEvalResult>()));
        var vm = new ComputerUseSettingsViewModel(browser: browser) { BrowserCheckUrl = target };

        await vm.RunBrowserCheck();

        Assert.False(vm.CanRunBrowserCheck);
        Assert.Equal(0, browser.Calls);
        Assert.Equal("Enter a public HTTP or HTTPS URL.", vm.BrowserCheckStatus);
    }
}
