namespace OpenBurnBar.Storage;

/// <summary>
/// A <c>token_usage</c> row — the Windows-side mirror of the Mac
/// <c>AgentLens/Services/DataStore/UsageStore</c> <c>TokenUsage</c> model. Only
/// the columns the production <c>upsertUsage</c> statement writes are modeled;
/// nullable/derived columns keep their schema defaults.
/// </summary>
public sealed record TokenUsageRecord
{
    public required string Id { get; init; }
    public required string Provider { get; init; }
    public required string SessionId { get; init; }
    public required string ProjectName { get; init; }
    public required string Model { get; init; }

    public long InputTokens { get; init; }
    public long OutputTokens { get; init; }
    public long CacheCreationTokens { get; init; }
    public long CacheReadTokens { get; init; }
    public long ReasoningTokens { get; init; }
    public long TotalTokens { get; init; }
    public double Cost { get; init; }

    /// <summary>ISO-ish datetime text, matching GRDB's <c>.datetime</c> storage ("yyyy-MM-dd HH:mm:ss.fff").</summary>
    public required string StartTime { get; init; }
    public required string EndTime { get; init; }
    public required string CreatedAt { get; init; }

    public string UsageSource { get; init; } = "measured";
    public string ExecutionSourceID { get; init; } = "unknown";
    public string ExecutionSourceName { get; init; } = "Unknown";
    public string ExecutionSourceKind { get; init; } = "unknown";
    public string ExecutionSourceConfidence { get; init; } = "unknown";
    public string? SourceDeviceId { get; init; }
    public string? SourceDeviceName { get; init; }
    public bool IsRemote { get; init; }

    public string? ProviderID { get; init; }
    public string? ProviderAccountID { get; init; }
    public string? ProviderAccountLabel { get; init; }
    public string? ProviderAccountSource { get; init; }

    public string ProvenanceMethod { get; init; } = "api";
    public string ProvenanceConfidence { get; init; } = "exact";
    public string EstimatorVersion { get; init; } = "win-writeseam-1";
    public string? ParentRequestID { get; init; }

    /// <summary>
    /// Billing provenance (<c>api</c> / <c>subscription</c> / <c>unknown</c>) — v60.
    /// <c>null</c> means "classify me at write time" and the seam derives it from
    /// <see cref="Provider"/> + <see cref="UsageSource"/> via
    /// <see cref="BillingProvenance.Classify"/>, mirroring the Mac
    /// <c>UsageStore.upsertUsage</c> stamp. Set it explicitly only when the caller
    /// already knows the kind from the ingest route.
    /// </summary>
    public string? BillingKind { get; init; }

    /// <summary>The kind actually persisted: the stamped value, else the classifier's.</summary>
    public string EffectiveBillingKind =>
        BillingKind ?? BillingProvenance.Classify(Provider, UsageSource);
}
