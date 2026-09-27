// The Windows resolve site for the swarm gate-policy layer: the single call
// that composes persisted prefs + live platform sensors into a resolved
// render plan. The iOS analog is the `SwarmBackgroundPowerPolicy.resolve`
// call block in `ConstellationBackgroundView.body`
// (OpenBurnBarMobile/Views/Aurora/ConstellationBackgroundView.swift); the
// Android analog is the gate block in `SwarmBackground`
// (android/.../ui/components/SwarmBackground.kt).
//
// Dependency-free (System-only) and platform-agnostic like the rest of
// Policy/: the WinUI owner (`SwarmRenderPlanOwner`, which only Windows/CI
// exercises live) only reads prefs + WinRT sensors and calls this, so every
// gating decision stays unit-tested here.

using System;

namespace OpenBurnBar.Particles.Policy;

/// <summary>
/// Live platform sensor readings for the swarm power policy. Mirrors the
/// Android <c>SwarmEnvironmentSnapshot</c> (plus the reduce-motion bit, which
/// Android reads from composition locals instead).
/// </summary>
/// <remarks>
/// The struct default (all <c>false</c>) is fail-closed: an inactive scene
/// resolves to <see cref="SwarmBackgroundRenderPlan.StaticBackdrop"/>, so a
/// host that never snapshots sensors renders at most one static frame.
/// </remarks>
public readonly record struct SwarmEnvironmentSnapshot(
    bool IsPowerConnected,
    bool IsWifiConnected,
    bool ScenePhaseActive,
    bool IsLowPowerModeEnabled,
    bool ReduceMotion);

/// <summary>
/// Resolves prefs + sensors to a render plan in one call: constrain the
/// requested visibility by the inherited one (iOS
/// <c>visibility.constrained(by:)</c>), evaluate the persisted condition
/// against the power/wifi sensors, then run the order-sensitive
/// <see cref="SwarmBackgroundPowerPolicy.Resolve"/> guard chain.
/// </summary>
public static class SwarmPlanResolver
{
    /// <summary>
    /// Runs the full resolve chain. <paramref name="requestedVisibility"/>
    /// is the view's own ask; <paramref name="inheritedVisibility"/> is the
    /// ambient ask from the surrounding surface (both prominent when the
    /// host has no visibility producer, which preserves the historical
    /// always-on look).
    /// </summary>
    public static SwarmBackgroundRenderPlan Resolve(
        SwarmBackgroundPreferences preferences,
        SwarmEnvironmentSnapshot sensors,
        MobileBackgroundVisibility requestedVisibility = MobileBackgroundVisibility.Prominent,
        MobileBackgroundVisibility inheritedVisibility = MobileBackgroundVisibility.Prominent)
    {
        ArgumentNullException.ThrowIfNull(preferences);

        MobileBackgroundVisibility effectiveVisibility =
            requestedVisibility.Constrained(inheritedVisibility);
        bool conditionMet = SwarmEnvironmentConditionEvaluator.MeetsCondition(
            preferences.Condition, sensors.IsPowerConnected, sensors.IsWifiConnected);
        return SwarmBackgroundPowerPolicy.Resolve(
            preferences.Location,
            conditionMet,
            effectiveVisibility,
            sensors.ScenePhaseActive,
            sensors.IsLowPowerModeEnabled,
            sensors.ReduceMotion);
    }
}
