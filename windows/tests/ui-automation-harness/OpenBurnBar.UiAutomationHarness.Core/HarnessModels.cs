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

public sealed record RouteSmokeEvidence(
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
    string? Message);

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
    bool RequiresCapabilityToken);

public sealed record UiHarnessRunSummary(
    string GeneratedAtUtc,
    string RepoRoot,
    string AppExe,
    string OutputDirectory,
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

            return HarnessVerdict.Pass;
        }
    }
}
