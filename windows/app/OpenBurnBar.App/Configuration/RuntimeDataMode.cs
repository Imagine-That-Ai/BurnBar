using System;

namespace OpenBurnBar.App.Configuration;

/// <summary>
/// Central switch for demo/sample data. Production routes must not silently fabricate data when
/// credentials are absent; demos opt in with OPENBURNBAR_SAMPLE_MODE=1.
/// </summary>
internal static class RuntimeDataMode
{
    public static bool SampleModeEnabled => IsTruthy(Environment.GetEnvironmentVariable("OPENBURNBAR_SAMPLE_MODE"));

    public static string EmptyStateDetail(string configuredSource) =>
        SampleModeEnabled
            ? "Sample mode is enabled. Demo data is labeled and should not be treated as live usage."
            : $"Connect {configuredSource} in Settings → Data Sources, or launch with OPENBURNBAR_SAMPLE_MODE=1 for a labeled demo.";

    private static bool IsTruthy(string? value) =>
        string.Equals(value, "1", StringComparison.OrdinalIgnoreCase)
        || string.Equals(value, "true", StringComparison.OrdinalIgnoreCase)
        || string.Equals(value, "yes", StringComparison.OrdinalIgnoreCase)
        || string.Equals(value, "sample", StringComparison.OrdinalIgnoreCase)
        || string.Equals(value, "demo", StringComparison.OrdinalIgnoreCase);
}
