using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.UsageRuntime;

public interface IUsageEngine
{
    ValueTask<UsageEngineScanResponse> ScanAsync(
        UsageEngineScanRequest request,
        CancellationToken cancellationToken = default);
}

public sealed record UsageEngineScanRequest
{
    [JsonPropertyName("supportDirectory")]
    public required string SupportDirectory { get; init; }

    [JsonPropertyName("homeDirectory")]
    public required string HomeDirectory { get; init; }

    [JsonPropertyName("claudeProjectsDirectory")]
    public required string ClaudeProjectsDirectory { get; init; }

    [JsonPropertyName("codexHomeDirectory")]
    public required string CodexHomeDirectory { get; init; }

    [JsonPropertyName("cursorSessionsDirectory")]
    public required string CursorSessionsDirectory { get; init; }

    [JsonPropertyName("factorySessionsDirectory")]
    public required string FactorySessionsDirectory { get; init; }

    [JsonPropertyName("hermesHomeDirectory")]
    public required string HermesHomeDirectory { get; init; }

    [JsonPropertyName("includeConversationBodies")]
    public bool IncludeConversationBodies { get; init; } = true;
}

public sealed record WindowsUsagePaths(
    UsageEngineScanRequest ScanRequest,
    IReadOnlyList<string> WatchDirectories)
{
    public static WindowsUsagePaths ForCurrentUser(
        string? supportDirectory = null,
        bool includeConversationBodies = true)
    {
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (string.IsNullOrWhiteSpace(home))
        {
            throw new UsageRuntimeException(
                UsageRuntimeFailureKind.PathDiscovery,
                "Windows could not resolve the current user profile.");
        }

        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localAppData))
        {
            localAppData = Path.Combine(home, "AppData", "Local");
        }

        string parserSupport = supportDirectory
            ?? Path.Combine(localAppData, "OpenBurnBar", "parser-cache");
        string claude = Path.Combine(home, ".claude", "projects");
        string codex = Path.Combine(home, ".codex");
        string cursor = Path.Combine(home, ".cursor-agent", "sessions");
        string factory = Path.Combine(home, ".factory", "sessions");
        string hermes = Path.Combine(home, ".hermes");

        return new WindowsUsagePaths(
            new UsageEngineScanRequest
            {
                SupportDirectory = parserSupport,
                HomeDirectory = home,
                ClaudeProjectsDirectory = claude,
                CodexHomeDirectory = home,
                CursorSessionsDirectory = cursor,
                FactorySessionsDirectory = factory,
                HermesHomeDirectory = hermes,
                IncludeConversationBodies = includeConversationBodies,
            },
            new[] { claude, codex, cursor, factory, hermes });
    }
}

public sealed record UsageEngineScanResponse
{
    [JsonPropertyName("ok")]
    public bool Ok { get; init; }

    [JsonPropertyName("error")]
    public string? Error { get; init; }

    [JsonPropertyName("providers")]
    public IReadOnlyList<UsageProviderScanResult> Providers { get; init; } = Array.Empty<UsageProviderScanResult>();

    [JsonPropertyName("usages")]
    public IReadOnlyList<UsageEngineRecord> Usages { get; init; } = Array.Empty<UsageEngineRecord>();

    [JsonPropertyName("conversations")]
    public IReadOnlyList<UsageEngineConversation> Conversations { get; init; } = Array.Empty<UsageEngineConversation>();
}

[JsonConverter(typeof(JsonStringEnumConverter<UsageProviderScanStatus>))]
public enum UsageProviderScanStatus
{
    Succeeded,
    Missing,
    Failed,
}

public sealed record UsageProviderScanResult
{
    [JsonPropertyName("provider")]
    public required string Provider { get; init; }

    [JsonPropertyName("status")]
    public UsageProviderScanStatus Status { get; init; }

    [JsonPropertyName("usageCount")]
    public int UsageCount { get; init; }

    [JsonPropertyName("conversationCount")]
    public int ConversationCount { get; init; }

    [JsonPropertyName("error")]
    public string? Error { get; init; }
}

public sealed record UsageEngineRecord
{
    [JsonPropertyName("id")]
    public required string Id { get; init; }

    [JsonPropertyName("provider")]
    public required string Provider { get; init; }

    [JsonPropertyName("sessionId")]
    public required string SessionId { get; init; }

    [JsonPropertyName("projectName")]
    public required string ProjectName { get; init; }

    [JsonPropertyName("model")]
    public required string Model { get; init; }

    [JsonPropertyName("inputTokens")]
    public long InputTokens { get; init; }

    [JsonPropertyName("outputTokens")]
    public long OutputTokens { get; init; }

    [JsonPropertyName("cacheCreationTokens")]
    public long CacheCreationTokens { get; init; }

    [JsonPropertyName("cacheReadTokens")]
    public long CacheReadTokens { get; init; }

    [JsonPropertyName("reasoningTokens")]
    public long ReasoningTokens { get; init; }

    [JsonPropertyName("totalTokens")]
    public long TotalTokens { get; init; }

    [JsonPropertyName("costNanoUSD")]
    public long CostNanoUsd { get; init; }

    [JsonPropertyName("startUnixMilliseconds")]
    public long StartUnixMilliseconds { get; init; }

    [JsonPropertyName("endUnixMilliseconds")]
    public long EndUnixMilliseconds { get; init; }

    [JsonPropertyName("createdUnixMilliseconds")]
    public long CreatedUnixMilliseconds { get; init; }

    [JsonPropertyName("usageSource")]
    public required string UsageSource { get; init; }

    [JsonPropertyName("providerID")]
    public required string ProviderId { get; init; }

    [JsonPropertyName("providerAccountID")]
    public string? ProviderAccountId { get; init; }

    [JsonPropertyName("providerAccountLabel")]
    public string? ProviderAccountLabel { get; init; }

    [JsonPropertyName("providerAccountSource")]
    public string? ProviderAccountSource { get; init; }

    [JsonPropertyName("provenanceMethod")]
    public required string ProvenanceMethod { get; init; }

    [JsonPropertyName("provenanceConfidence")]
    public required string ProvenanceConfidence { get; init; }

    [JsonPropertyName("estimatorVersion")]
    public required string EstimatorVersion { get; init; }

    [JsonPropertyName("parentRequestID")]
    public string? ParentRequestId { get; init; }

    [JsonIgnore]
    public double CostUsd => CostNanoUsd / 1_000_000_000d;
}

public sealed record UsageEngineConversation
{
    [JsonPropertyName("id")]
    public required string Id { get; init; }

    [JsonPropertyName("provider")]
    public required string Provider { get; init; }

    [JsonPropertyName("sessionId")]
    public required string SessionId { get; init; }

    [JsonPropertyName("projectName")]
    public required string ProjectName { get; init; }

    [JsonPropertyName("inferredTaskTitle")]
    public required string InferredTaskTitle { get; init; }

    [JsonPropertyName("fullText")]
    public required string FullText { get; init; }

    [JsonPropertyName("indexedUnixMilliseconds")]
    public long IndexedUnixMilliseconds { get; init; }

    [JsonPropertyName("messageCount")]
    public int MessageCount { get; init; }

    [JsonPropertyName("workingDirectory")]
    public string? WorkingDirectory { get; init; }
}
