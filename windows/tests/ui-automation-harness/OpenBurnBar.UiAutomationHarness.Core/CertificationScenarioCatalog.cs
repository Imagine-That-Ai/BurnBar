using System;
using System.Collections.Generic;

namespace OpenBurnBar.UiAutomationHarness.Core;

public static class CertificationScenarioCatalog
{
    public const string BaselineProfile = "baseline";
    public const string AccessibilityProfile = "accessibility";
    public const string AllProfile = "all";

    private static readonly UiCertificationScenario BaselineScenario = new(
        Key: "baseline",
        Title: "Default route smoke and screenshot pass",
        Category: "default",
        RouteKeys: Array.Empty<string>(),
        AppearanceMode: null,
        ReduceTransparency: null,
        DpiScalePercent: null,
        RequiresScreenshots: true,
        RequiresUiAutomation: true,
        RequiresKeyboardOnly: false,
        RequiresNarratorProtocol: false,
        Acceptance: "Every selected route renders a non-uniform screenshot and exposes its route-root UIA automation id.");

    private static readonly UiCertificationScenario HighContrastScenario = new(
        Key: "high-contrast",
        Title: "High contrast route roots",
        Category: "accessibility",
        RouteKeys: new[] { "dashboard", "chat", "settings", "onboarding", "dataControlCenter" },
        AppearanceMode: "highcontrast",
        ReduceTransparency: true,
        DpiScalePercent: null,
        RequiresScreenshots: true,
        RequiresUiAutomation: true,
        RequiresKeyboardOnly: false,
        RequiresNarratorProtocol: true,
        Acceptance: "Representative primary routes render through the real high-contrast theme path with solid chrome and route-root UIA anchors.");

    private static readonly UiCertificationScenario ReducedTransparencyScenario = new(
        Key: "reduced-transparency",
        Title: "Reduced transparency route roots",
        Category: "accessibility",
        RouteKeys: new[] { "dashboard", "quota", "missionControl", "memory" },
        AppearanceMode: "dark",
        ReduceTransparency: true,
        DpiScalePercent: null,
        RequiresScreenshots: true,
        RequiresUiAutomation: true,
        RequiresKeyboardOnly: false,
        RequiresNarratorProtocol: false,
        Acceptance: "Representative high-motion/glass surfaces render with transparency disabled through the production theme service.");

    private static readonly UiCertificationScenario Dpi100Scenario = new(
        Key: "dpi-100",
        Title: "100 percent DPI screenshot baseline",
        Category: "dpi",
        RouteKeys: new[] { "dashboard", "settings", "chat" },
        AppearanceMode: "dark",
        ReduceTransparency: null,
        DpiScalePercent: 100,
        RequiresScreenshots: true,
        RequiresUiAutomation: true,
        RequiresKeyboardOnly: false,
        RequiresNarratorProtocol: false,
        Acceptance: "CI captures non-uniform screenshots for dense routes at the hosted Windows default DPI.");

    private static readonly UiCertificationScenario KeyboardOnlyScenario = new(
        Key: "keyboard-contract",
        Title: "Keyboard and input safety contract",
        Category: "keyboard",
        RouteKeys: Array.Empty<string>(),
        AppearanceMode: null,
        ReduceTransparency: null,
        DpiScalePercent: null,
        RequiresScreenshots: false,
        RequiresUiAutomation: false,
        RequiresKeyboardOnly: true,
        RequiresNarratorProtocol: true,
        Acceptance: "The harness records the keyboard/input route contract and keeps non-bypassable actions token-gated.");

    public static IReadOnlyList<UiCertificationScenario> Select(string? profile)
    {
        string normalized = string.IsNullOrWhiteSpace(profile)
            ? BaselineProfile
            : profile.Trim().ToLowerInvariant();
        return normalized switch
        {
            BaselineProfile => new[] { BaselineScenario },
            AccessibilityProfile => new[] { BaselineScenario, HighContrastScenario, ReducedTransparencyScenario, Dpi100Scenario, KeyboardOnlyScenario },
            AllProfile => new[] { BaselineScenario, HighContrastScenario, ReducedTransparencyScenario, Dpi100Scenario, KeyboardOnlyScenario },
            _ => throw new ArgumentException($"Unknown UI certification profile '{profile}'. Expected baseline, accessibility, or all.", nameof(profile)),
        };
    }
}
