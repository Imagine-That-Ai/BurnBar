using System;
using System.Globalization;
using System.IO;
using System.Text;
using OpenBurnBar.Storage;

namespace OpenBurnBar.B0Spike.Tests.Support;

/// <summary>Console readback stand-in for a Dashboard usage tile (spike proof).</summary>
public static class LiveTileReadback
{
    public static string FormatTile(TokenUsageRecord row)
    {
        var sb = new StringBuilder();
        sb.AppendLine("┌─ B0 live tile (token_usage readback) ─────────────");
        sb.AppendLine(string.Create(
            CultureInfo.InvariantCulture,
            $"│ {row.Provider} · {row.Model} · session {row.SessionId}"));
        sb.AppendLine(string.Create(
            CultureInfo.InvariantCulture,
            $"│ tokens in={row.InputTokens} out={row.OutputTokens} total={row.TotalTokens} · cost=${row.Cost:F6}"));
        sb.AppendLine("└──────────────────────────────────────────────────");
        return sb.ToString();
    }

    public static TokenUsageRecord FromParserContract(
        ParserContractUsage usage,
        string rowId)
    {
        const string frozen = "2025-07-01 00:00:00.000";
        return new TokenUsageRecord
        {
            Id = rowId,
            Provider = usage.Provider,
            SessionId = usage.SessionId,
            ProjectName = usage.ProjectName,
            Model = usage.Model,
            InputTokens = usage.InputTokens,
            OutputTokens = usage.OutputTokens,
            CacheCreationTokens = usage.CacheCreationTokens,
            CacheReadTokens = usage.CacheReadTokens,
            ReasoningTokens = usage.ReasoningTokens,
            TotalTokens = usage.TotalTokens,
            Cost = usage.CostUsd,
            StartTime = frozen,
            EndTime = frozen,
            CreatedAt = frozen,
            UsageSource = usage.UsageSource,
            ProvenanceMethod = usage.ProvenanceMethod,
            ProvenanceConfidence = usage.ProvenanceConfidence,
            EstimatorVersion = string.IsNullOrEmpty(usage.EstimatorVersion)
                ? "b0-spike-golden"
                : usage.EstimatorVersion,
        };
    }

    public static string CopyDbFixture()
    {
        string source = Path.Combine(AppContext.BaseDirectory, "Fixtures", "openburnbar-db-compat-v64.sqlcipher");
        string dest = Path.Combine(Path.GetTempPath(), $"b0-spike-{Guid.NewGuid():N}.sqlcipher");
        File.Copy(source, dest, overwrite: true);
        return dest;
    }
}
