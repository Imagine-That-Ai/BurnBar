using OpenBurnBar.UiAutomationHarness.Core;
using Xunit;

namespace OpenBurnBar.UiAutomationHarness.Tests;

public sealed class ReportWriterTests : IDisposable
{
    private readonly string _dir;

    public ReportWriterTests()
    {
        _dir = Path.Combine(Path.GetTempPath(), "obb-ui-harness-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_dir);
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(_dir))
            {
                Directory.Delete(_dir, recursive: true);
            }
        }
        catch (IOException)
        {
            // Best-effort temp cleanup; never fail a test on teardown.
        }
    }

    [Fact]
    public void JUnitReportWriter_EmitsFailureForFailedRoute()
    {
        UiHarnessRunSummary summary = CreateSummary(HarnessVerdict.Fail, "client_secret=supersecretvalue");
        string path = Path.Combine(_dir, "junit.xml");

        JUnitReportWriter.Write(path, summary, new ArtifactRedactor());

        string xml = File.ReadAllText(path);
        Assert.Contains("tests=\"3\"", xml);
        Assert.Contains("failures=\"1\"", xml);
        Assert.Contains("route.dashboard", xml);
        Assert.Contains("[REDACTED]", xml);
        Assert.DoesNotContain("supersecretvalue", xml);
    }

    [Fact]
    public void HtmlReportWriter_LinksScreenshotRelatively()
    {
        string screenshot = Path.Combine(_dir, "routes", "dashboard", "dashboard.png");
        Directory.CreateDirectory(Path.GetDirectoryName(screenshot)!);
        File.WriteAllText(screenshot, "not a real png");
        UiHarnessRunSummary summary = CreateSummary(HarnessVerdict.Pass, null, screenshot);
        string path = Path.Combine(_dir, "index.html");

        HtmlReportWriter.Write(path, summary, new ArtifactRedactor());

        string html = File.ReadAllText(path);
        Assert.Contains("routes/dashboard/dashboard.png", html.Replace('\\', '/'));
        Assert.Contains("OpenBurnBar Windows UI Automation", html);
    }

    [Fact]
    public void HtmlReportWriter_RedactsInputRouteMessages()
    {
        string factoryKey = "fk-" + new string('B', 24);
        UiHarnessRunSummary summary = CreateSummary(
            HarnessVerdict.Pass,
            message: null,
            inputRoutes: new[]
            {
                new InputRouteEvidence(
                    "Click",
                    "NonBypassable",
                    "mac.input.click",
                    RequiresCapabilityToken: true,
                    HarnessVerdict.Fail,
                    $"/Users/alberto/project {factoryKey}")
            });
        string path = Path.Combine(_dir, "index.html");

        HtmlReportWriter.Write(path, summary, new ArtifactRedactor("/Users/alberto/project"));

        string html = File.ReadAllText(path);
        Assert.Contains("[REDACTED_PATH]", html);
        Assert.Contains("[REDACTED_FACTORY_KEY]", html);
        Assert.DoesNotContain(factoryKey, html);
        Assert.DoesNotContain("/Users/alberto/project", html);
    }

    [Fact]
    public void ArtifactRedactor_ScrubsFactoryKeysAndPathPrefixes()
    {
        var redactor = new ArtifactRedactor("/Users/alberto/project");

        string factoryKey = "fk-" + new string('A', 24);
        string token = "to" + "ken:" + "abc123456789";
        string redacted = redactor.Redact($"/Users/alberto/project {factoryKey} {token}");

        Assert.Contains("[REDACTED_PATH]", redacted);
        Assert.Contains("[REDACTED_FACTORY_KEY]", redacted);
        Assert.Contains("token:[REDACTED]", redacted);
    }

    [Fact]
    public void ArtifactRedactor_ScrubsJsonEscapedWindowsPathPrefixes()
    {
        var redactor = new ArtifactRedactor(@"C:\Users\Alberto\project");

        string redacted = redactor.Redact(@"{""RepoRoot"":""C:\\Users\\Alberto\\project"",""AppExe"":""C:\\Users\\Alberto\\project\\OpenBurnBar.App.exe""}");

        Assert.Contains("[REDACTED_PATH]", redacted);
        Assert.DoesNotContain(@"C:\\Users\\Alberto\\project", redacted);
    }

    [Fact]
    public void SummaryVerdict_FailsWhenInputRouteContractFails()
    {
        UiHarnessRunSummary summary = CreateSummary(
            HarnessVerdict.Pass,
            message: null,
            inputRoutes: new[]
            {
                new InputRouteEvidence(
                    "Click",
                    "Advisory",
                    "mac.input.click",
                    RequiresCapabilityToken: false,
                    HarnessVerdict.Fail,
                    "Expected NonBypassable with tokenRequired=True; got Advisory with tokenRequired=False.")
            });

        Assert.Equal(HarnessVerdict.Fail, summary.Verdict);
    }

    private static UiHarnessRunSummary CreateSummary(
        HarnessVerdict routeVerdict,
        string? message,
        string? screenshotPath = null,
        IReadOnlyList<InputRouteEvidence>? inputRoutes = null) =>
        new(
            GeneratedAtUtc: "2026-07-09T00:00:00.0000000Z",
            RepoRoot: "/repo",
            AppExe: "/repo/OpenBurnBar.App.exe",
            OutputDirectory: "/out",
            Manifest: DefaultRouteCatalog.Select(new[] { "dashboard" }),
            Routes: new[]
            {
                new RouteSmokeEvidence(
                    "dashboard",
                    routeVerdict,
                    ExitCode: routeVerdict == HarnessVerdict.Pass ? 0 : 1,
                    TimedOut: false,
                    NearUniform: routeVerdict != HarnessVerdict.Pass,
                    ScreenshotPath: screenshotPath,
                    ResultPath: "/out/routes/dashboard/dashboard-result.json",
                    Width: 1200,
                    Height: 800,
                    LumaStdDev: 14.2,
                    ElapsedMs: 450,
                    Message: message,
                    ExpectedAutomationId: "RouteRoot.dashboard",
                    ExpectedAutomationIdFound: routeVerdict == HarnessVerdict.Pass),
            },
            SemanticProbe: new SemanticProbeEvidence(
                HarnessVerdict.Pass,
                ProcessImageName: "OpenBurnBar.App.exe",
                WindowTitle: "OpenBurnBar",
                IsPasswordField: false,
                IsSecureDesktop: false,
                IsCredentialPrompt: false,
                ScreenshotPath: null,
                Message: "ok"),
            InputRoutes: inputRoutes ?? new[]
            {
                new InputRouteEvidence(
                    "Click",
                    "NonBypassable",
                    "mac.input.click",
                    RequiresCapabilityToken: true,
                    HarnessVerdict.Pass,
                    Message: null),
            },
            Notes: Array.Empty<string>());
}
