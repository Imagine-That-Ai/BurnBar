using System;

namespace OpenBurnBar.Integrations.SmartHub.Bridge;

// Dashboard time-period selection.
//
// Parity: OpenBurnBarCore/.../SharedModels/SmartHubConfig.swift
//   enum SmartHubTimePeriod (rawValue / displayName / shortLabel / spanHours).

public enum SmartHubTimePeriod
{
    Rolling5h,
    Rolling24h,
    Rolling7d,
    Rolling30d,
}

public static class SmartHubTimePeriodExtensions
{
    /// All cases in declaration order (parity with Swift CaseIterable.allCases).
    public static readonly SmartHubTimePeriod[] AllCases =
    {
        SmartHubTimePeriod.Rolling5h,
        SmartHubTimePeriod.Rolling24h,
        SmartHubTimePeriod.Rolling7d,
        SmartHubTimePeriod.Rolling30d,
    };

    public static string RawValue(this SmartHubTimePeriod period) => period switch
    {
        SmartHubTimePeriod.Rolling5h => "rolling5h",
        SmartHubTimePeriod.Rolling24h => "rolling24h",
        SmartHubTimePeriod.Rolling7d => "rolling7d",
        SmartHubTimePeriod.Rolling30d => "rolling30d",
        _ => "rolling5h",
    };

    public static string DisplayName(this SmartHubTimePeriod period) => period switch
    {
        SmartHubTimePeriod.Rolling5h => "Last 5 hours",
        SmartHubTimePeriod.Rolling24h => "Last 24 hours",
        SmartHubTimePeriod.Rolling7d => "Last 7 days",
        SmartHubTimePeriod.Rolling30d => "Last 30 days",
        _ => "Last 5 hours",
    };

    public static string ShortLabel(this SmartHubTimePeriod period) => period switch
    {
        SmartHubTimePeriod.Rolling5h => "5h",
        SmartHubTimePeriod.Rolling24h => "24h",
        SmartHubTimePeriod.Rolling7d => "7d",
        SmartHubTimePeriod.Rolling30d => "30d",
        _ => "5h",
    };

    public static double SpanHours(this SmartHubTimePeriod period) => period switch
    {
        SmartHubTimePeriod.Rolling5h => 5,
        SmartHubTimePeriod.Rolling24h => 24,
        SmartHubTimePeriod.Rolling7d => 24 * 7,
        SmartHubTimePeriod.Rolling30d => 24 * 30,
        _ => 5,
    };

    /// Parses the Swift raw value, or null when unrecognized.
    public static SmartHubTimePeriod? Parse(string? rawValue) => rawValue switch
    {
        "rolling5h" => SmartHubTimePeriod.Rolling5h,
        "rolling24h" => SmartHubTimePeriod.Rolling24h,
        "rolling7d" => SmartHubTimePeriod.Rolling7d,
        "rolling30d" => SmartHubTimePeriod.Rolling30d,
        _ => null,
    };
}
