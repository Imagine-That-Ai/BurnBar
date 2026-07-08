using System;

namespace OpenBurnBar.App.Presentation.MissionControl;

// PORTED (faithful) from MissionConsoleForecastComputer in
// OpenBurnBarCore/.../Views/MissionControl/MissionConsoleTypes.swift. A pure function so
// the forecast band the composer previews is locked by unit tests regardless of platform.

/// <summary>Computes the pre-dispatch token / cost / ETA band from a draft + runtime.</summary>
public static class MissionForecastComputer
{
    // Cost mix: $3 per 1M input + $15 per 1M output, 70/30 split (matches the Swift).
    private const double MixCostPerToken = ((3.0 * 0.7) + (15.0 * 0.3)) / 1_000_000.0;
    private const double BaselineTokens = 12_000.0;

    /// <summary>Forecast a draft dispatched to <paramref name="runtime"/>.</summary>
    public static MissionForecast Forecast(
        MissionKind kind,
        MissionDepth depth,
        MissionRuntime runtime)
    {
        if (runtime is null)
        {
            throw new ArgumentNullException(nameof(runtime));
        }

        double kindMul = MissionKindInfo.TokenMultiplier(kind);
        double depthMul = MissionDepthInfo.Coefficient(depth);
        double runtimeMul = runtime.PricingFactor;

        double centerTokens = BaselineTokens * kindMul * depthMul * runtimeMul;

        // +/-30% band, widened for deep/creative where output variance is high.
        double widen = (depth == MissionDepth.Deep || kind == MissionKind.Creative) ? 0.45 : 0.30;
        int tokensLow = (int)Math.Round(centerTokens * (1.0 - widen), MidpointRounding.AwayFromZero);
        int tokensHigh = (int)Math.Round(centerTokens * (1.0 + widen), MidpointRounding.AwayFromZero);

        double centerCost = centerTokens * MixCostPerToken;
        if (runtime.RecentMedianBurnUsd is double median && median > 0)
        {
            // Blend forecast with historical median 50/50 to soak up reality.
            centerCost = (centerCost + median) / 2.0;
        }

        double costLow = Math.Max(0, centerCost * (1.0 - widen));
        double costHigh = centerCost * (1.0 + widen);

        // ETA: standard runs ~2min/k-tokens, scaled by 0.6, tuned by the band.
        double centerEta = (centerTokens / 1000.0) * 120.0 * 0.6;
        double etaLow = Math.Max(0, centerEta * (1.0 - widen));
        double etaHigh = centerEta * (1.0 + widen);

        return new MissionForecast(
            tokensLow: tokensLow,
            tokensHigh: tokensHigh,
            costLowUsd: costLow,
            costHighUsd: costHigh,
            etaLowSeconds: etaLow,
            etaHighSeconds: etaHigh);
    }

    /// <summary>Recommendation the dispatch envelope carries — mirrors
    /// <c>MissionConsoleMacHost.recommendation(for:)</c>.</summary>
    public static MissionRecommendation Recommendation(
        MissionDepth depth,
        MissionApprovalMode approvalMode,
        bool commandsAllowed,
        bool fileEditsAllowed)
    {
        if (commandsAllowed && fileEditsAllowed && approvalMode == MissionApprovalMode.RequireApproval)
        {
            return MissionRecommendation.Escalate;
        }

        if (approvalMode == MissionApprovalMode.RequireApproval)
        {
            return MissionRecommendation.Review;
        }

        return depth switch
        {
            MissionDepth.Light => MissionRecommendation.Proceed,
            MissionDepth.Standard => MissionRecommendation.Review,
            MissionDepth.Deep => MissionRecommendation.Review,
            _ => MissionRecommendation.Review,
        };
    }
}
