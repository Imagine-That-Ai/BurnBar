using System;
using System.Collections.Generic;

namespace OpenBurnBar.UiAutomationHarness.Core;

public enum HarnessVerdict
{
    Pass,
    Fail,
    Skipped,
}

public sealed record UiHarnessRoute(
    string Key,
    string Title,
    string ExpectedAutomationId,
    string XamlPath);

public static class UiHarnessRouteDefaults
{
    public static string ExpectedAutomationId(string routeKey) => $"RouteRoot.{routeKey}";
}

public sealed record UiCertificationScenario(
    string Key,
    string Title,
    string Category,
    IReadOnlyList<string> RouteKeys,
    string? AppearanceMode,
    bool? ReduceTransparency,
    int? DpiScalePercent,
    bool RequiresScreenshots,
    bool RequiresUiAutomation,
    bool RequiresKeyboardOnly,
    bool RequiresNarratorProtocol,
    string Acceptance);

public sealed record RouteSmokeEvidence(
    string ScenarioKey,
    string ScenarioTitle,
    string RouteKey,
    HarnessVerdict Verdict,
    int ExitCode,
    bool TimedOut,
    bool NearUniform,
    string? ScreenshotPath,
    string? ResultPath,
    double Width,
    double Height,
    double LumaStdDev,
    double ElapsedMs,
    string? Message,
    string? AppearanceMode,
    bool? ReduceTransparency,
    int? DpiScalePercent,
    string ExpectedAutomationId,
    bool ExpectedAutomationIdFound);

public sealed record SemanticProbeEvidence(
    HarnessVerdict Verdict,
    string? ProcessImageName,
    string? WindowTitle,
    bool IsPasswordField,
    bool IsSecureDesktop,
    bool IsCredentialPrompt,
    string? ScreenshotPath,
    string? Message);

public sealed record InputRouteEvidence(
    string ActionKind,
    string DispatchRoute,
    string AuditKind,
    bool RequiresCapabilityToken,
    HarnessVerdict Verdict,
    string? Message);

public sealed record UiHarnessRunSummary(
    string GeneratedAtUtc,
    string RepoRoot,
    string AppExe,
    string OutputDirectory,
    string CertificationProfile,
    IReadOnlyList<UiCertificationScenario> Scenarios,
    IReadOnlyList<UiHarnessRoute> Manifest,
    IReadOnlyList<RouteSmokeEvidence> Routes,
    SemanticProbeEvidence? SemanticProbe,
    IReadOnlyList<InputRouteEvidence> InputRoutes,
    IReadOnlyList<string> Notes)
{
    public HarnessVerdict Verdict
    {
        get
        {
            if (SemanticProbe?.Verdict == HarnessVerdict.Fail)
            {
                return HarnessVerdict.Fail;
            }

            foreach (RouteSmokeEvidence route in Routes)
            {
                if (route.Verdict == HarnessVerdict.Fail)
                {
                    return HarnessVerdict.Fail;
                }
            }

            foreach (InputRouteEvidence input in InputRoutes)
            {
                if (input.Verdict == HarnessVerdict.Fail)
                {
                    return HarnessVerdict.Fail;
                }
            }

            return HarnessVerdict.Pass;
        }
    }
}
