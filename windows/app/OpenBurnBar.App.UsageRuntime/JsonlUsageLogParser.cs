using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using OpenBurnBar.Storage;

namespace OpenBurnBar.App.UsageRuntime;

public sealed class JsonlUsageLogParser : IUsageLogParser
{
    public const long DefaultMaxFileBytes = 128L * 1024 * 1024;
    public const int DefaultMaxConversationChars = 1_000_000;

    private static readonly string[] SessionAliases =
        { "session_id", "sessionId", "conversation_id", "conversationId", "thread_id", "threadId" };
    private static readonly string[] ModelAliases =
        { "model", "model_name", "modelName", "model_id", "modelId", "slug" };
    private static readonly string[] ProjectAliases =
        { "project_name", "projectName", "workspace", "workspace_name", "cwd", "working_directory" };
    private static readonly string[] TimestampAliases =
        { "timestamp", "created_at", "createdAt", "started_at", "startedAt", "time" };
    private static readonly string[] TextAliases =
        { "content", "text", "output_text", "input_text", "prompt", "response" };

    private readonly long _maxFileBytes;
    private readonly int _maxConversationChars;

    public JsonlUsageLogParser(
        long maxFileBytes = DefaultMaxFileBytes,
        int maxConversationChars = DefaultMaxConversationChars)
    {
        _maxFileBytes = Math.Max(1, maxFileBytes);
        _maxConversationChars = Math.Max(1, maxConversationChars);
    }

    public ParsedUsageLog Parse(DiscoveredUsageLog log, CancellationToken cancellationToken = default)
    {
        var info = new FileInfo(log.Path);
        if (info.Length > _maxFileBytes)
        {
            throw new InvalidDataException($"Provider log exceeds the {_maxFileBytes}-byte safety limit.");
        }

        var aggregates = new Dictionary<string, MutableUsage>(StringComparer.Ordinal);
        var conversation = new StringBuilder(Math.Min(_maxConversationChars, 16_384));
        string fallbackSession = Path.GetFileNameWithoutExtension(log.Path);
        string sessionId = fallbackSession;
        string projectName = ProjectFromPath(log.Path);
        string? title = null;
        DateTimeOffset firstAt = info.CreationTimeUtc;
        DateTimeOffset lastAt = info.LastWriteTimeUtc;
        int messageCount = 0;

        using var stream = new FileStream(
            log.Path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete,
            64 * 1024,
            FileOptions.SequentialScan);
        using var reader = new StreamReader(stream, Encoding.UTF8, true, 64 * 1024, leaveOpen: false);

        string? line;
        while ((line = reader.ReadLine()) is not null)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (string.IsNullOrWhiteSpace(line))
            {
                continue;
            }

            try
            {
                using JsonDocument document = JsonDocument.Parse(line, new JsonDocumentOptions
                {
                    AllowTrailingCommas = true,
                    CommentHandling = JsonCommentHandling.Skip,
                    MaxDepth = 128,
                });
                JsonElement root = document.RootElement;
                sessionId = FindString(root, SessionAliases) ?? sessionId;
                projectName = NormalizeProject(FindString(root, ProjectAliases)) ?? projectName;
                DateTimeOffset timestamp = FindTimestamp(root) ?? lastAt;
                if (timestamp < firstAt) firstAt = timestamp;
                if (timestamp > lastAt) lastAt = timestamp;

                string model = FindString(root, ModelAliases) ?? "unknown";
                if (FindUsage(root) is { } usage && usage.TotalTokens > 0)
                {
                    string key = sessionId + "\n" + model;
                    if (!aggregates.TryGetValue(key, out MutableUsage? aggregate))
                    {
                        aggregate = new MutableUsage(sessionId, model, timestamp);
                        aggregates.Add(key, aggregate);
                    }

                    aggregate.Add(usage, timestamp, IsCumulativeProvider(log.Provider));
                }

                foreach (string text in FindText(root))
                {
                    if (string.IsNullOrWhiteSpace(text))
                    {
                        continue;
                    }

                    messageCount++;
                    title ??= MakeTitle(text);
                    AppendBounded(conversation, text, _maxConversationChars);
                }
            }
            catch (JsonException)
            {
                // A partially-written final JSONL line is normal during a live scan.
            }
        }

        string conversationId = StableId("conversation", log.Provider, sessionId, log.Path);
        ConversationRecord? conversationRecord = conversation.Length == 0 && aggregates.Count == 0
            ? null
            : new ConversationRecord(
                conversationId,
                log.Provider,
                sessionId,
                projectName,
                title ?? $"{DisplayName(log.Provider)} session",
                conversation.ToString(),
                FormatTimestamp(lastAt),
                messageCount);

        TokenUsageRecord[] rows = aggregates.Values.Select(aggregate => new TokenUsageRecord
        {
            Id = StableId("usage", log.Provider, aggregate.SessionId, aggregate.Model),
            Provider = log.Provider,
            SessionId = aggregate.SessionId,
            ProjectName = projectName,
            Model = aggregate.Model,
            InputTokens = aggregate.InputTokens,
            OutputTokens = aggregate.OutputTokens,
            CacheCreationTokens = aggregate.CacheCreationTokens,
            CacheReadTokens = aggregate.CacheReadTokens,
            ReasoningTokens = aggregate.ReasoningTokens,
            TotalTokens = aggregate.TotalTokens,
            Cost = aggregate.Cost,
            StartTime = FormatTimestamp(firstAt),
            EndTime = FormatTimestamp(aggregate.LastAt),
            CreatedAt = FormatTimestamp(aggregate.LastAt),
            UsageSource = "measured",
            ProviderID = log.Provider,
            ProvenanceMethod = "windows-provider-log",
            ProvenanceConfidence = "exact",
            EstimatorVersion = "windows-jsonl-v1",
        }).ToArray();

        return new ParsedUsageLog(rows, conversationRecord);
    }

    private static UsageValues? FindUsage(JsonElement element)
    {
        var queue = new Queue<JsonElement>();
        queue.Enqueue(element);
        while (queue.Count > 0)
        {
            JsonElement current = queue.Dequeue();
            if (current.ValueKind == JsonValueKind.Object)
            {
                UsageValues values = UsageValues.From(current);
                if (values.TotalTokens > 0)
                {
                    return values;
                }

                foreach (JsonProperty property in current.EnumerateObject())
                {
                    if (property.Value.ValueKind is JsonValueKind.Object or JsonValueKind.Array)
                    {
                        queue.Enqueue(property.Value);
                    }
                }
            }
            else if (current.ValueKind == JsonValueKind.Array)
            {
                foreach (JsonElement child in current.EnumerateArray()) queue.Enqueue(child);
            }
        }

        return null;
    }

    private static string? FindString(JsonElement element, IReadOnlyList<string> aliases)
    {
        var queue = new Queue<JsonElement>();
        queue.Enqueue(element);
        while (queue.Count > 0)
        {
            JsonElement current = queue.Dequeue();
            if (current.ValueKind == JsonValueKind.Object)
            {
                foreach (JsonProperty property in current.EnumerateObject())
                {
                    if (property.Value.ValueKind == JsonValueKind.String
                        && aliases.Contains(property.Name, StringComparer.OrdinalIgnoreCase))
                    {
                        string? value = property.Value.GetString();
                        if (!string.IsNullOrWhiteSpace(value)) return value;
                    }

                    if (property.Value.ValueKind is JsonValueKind.Object or JsonValueKind.Array)
                        queue.Enqueue(property.Value);
                }
            }
            else if (current.ValueKind == JsonValueKind.Array)
            {
                foreach (JsonElement child in current.EnumerateArray()) queue.Enqueue(child);
            }
        }

        return null;
    }

    private static DateTimeOffset? FindTimestamp(JsonElement element)
    {
        string? text = FindString(element, TimestampAliases);
        if (text is not null && DateTimeOffset.TryParse(
                text,
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                out DateTimeOffset parsed))
        {
            return parsed;
        }

        return null;
    }

    private static IEnumerable<string> FindText(JsonElement element)
    {
        var queue = new Queue<JsonElement>();
        queue.Enqueue(element);
        int emitted = 0;
        while (queue.Count > 0 && emitted < 32)
        {
            JsonElement current = queue.Dequeue();
            if (current.ValueKind == JsonValueKind.Object)
            {
                foreach (JsonProperty property in current.EnumerateObject())
                {
                    if (property.Value.ValueKind == JsonValueKind.String
                        && TextAliases.Contains(property.Name, StringComparer.OrdinalIgnoreCase))
                    {
                        string? value = property.Value.GetString();
                        if (!string.IsNullOrWhiteSpace(value) && value.Length <= 100_000)
                        {
                            emitted++;
                            yield return value;
                        }
                    }
                    else if (property.Value.ValueKind is JsonValueKind.Object or JsonValueKind.Array)
                    {
                        queue.Enqueue(property.Value);
                    }
                }
            }
            else if (current.ValueKind == JsonValueKind.Array)
            {
                foreach (JsonElement child in current.EnumerateArray()) queue.Enqueue(child);
            }
        }
    }

    private static string? NormalizeProject(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        string trimmed = value.TrimEnd('/', '\\');
        int separator = Math.Max(trimmed.LastIndexOf('/'), trimmed.LastIndexOf('\\'));
        return separator >= 0 ? trimmed.Substring(separator + 1) : trimmed;
    }

    private static string ProjectFromPath(string path)
    {
        DirectoryInfo? directory = Directory.GetParent(path);
        return directory?.Name ?? string.Empty;
    }

    private static string MakeTitle(string text)
    {
        string line = text.Replace('\r', ' ').Replace('\n', ' ').Trim();
        return line.Length <= 120 ? line : line.Substring(0, 117) + "...";
    }

    private static void AppendBounded(StringBuilder builder, string text, int maxChars)
    {
        if (builder.Length >= maxChars) return;
        if (builder.Length > 0) builder.AppendLine().AppendLine();
        int remaining = maxChars - builder.Length;
        builder.Append(text.AsSpan(0, Math.Min(text.Length, remaining)));
    }

    private static bool IsCumulativeProvider(string provider) =>
        provider.Equals("codex", StringComparison.OrdinalIgnoreCase)
        || provider.Equals("grok", StringComparison.OrdinalIgnoreCase);

    private static string StableId(params string[] parts)
    {
        byte[] hash = SHA256.HashData(Encoding.UTF8.GetBytes(string.Join("\n", parts)));
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    private static string FormatTimestamp(DateTimeOffset value) =>
        value.UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture);

    private static string DisplayName(string value) =>
        char.ToUpperInvariant(value[0]) + value.Substring(1);

    private sealed class MutableUsage
    {
        public MutableUsage(string sessionId, string model, DateTimeOffset at)
        {
            SessionId = sessionId;
            Model = model;
            LastAt = at;
        }

        public string SessionId { get; }
        public string Model { get; }
        public long InputTokens { get; private set; }
        public long OutputTokens { get; private set; }
        public long CacheCreationTokens { get; private set; }
        public long CacheReadTokens { get; private set; }
        public long ReasoningTokens { get; private set; }
        public long TotalTokens { get; private set; }
        public double Cost { get; private set; }
        public DateTimeOffset LastAt { get; private set; }

        public void Add(UsageValues value, DateTimeOffset at, bool cumulative)
        {
            if (cumulative)
            {
                InputTokens = Math.Max(InputTokens, value.InputTokens);
                OutputTokens = Math.Max(OutputTokens, value.OutputTokens);
                CacheCreationTokens = Math.Max(CacheCreationTokens, value.CacheCreationTokens);
                CacheReadTokens = Math.Max(CacheReadTokens, value.CacheReadTokens);
                ReasoningTokens = Math.Max(ReasoningTokens, value.ReasoningTokens);
                TotalTokens = Math.Max(TotalTokens, value.TotalTokens);
                Cost = Math.Max(Cost, value.Cost);
            }
            else
            {
                InputTokens += value.InputTokens;
                OutputTokens += value.OutputTokens;
                CacheCreationTokens += value.CacheCreationTokens;
                CacheReadTokens += value.CacheReadTokens;
                ReasoningTokens += value.ReasoningTokens;
                TotalTokens += value.TotalTokens;
                Cost += value.Cost;
            }

            if (at > LastAt) LastAt = at;
        }
    }

    private sealed record UsageValues(
        long InputTokens,
        long OutputTokens,
        long CacheCreationTokens,
        long CacheReadTokens,
        long ReasoningTokens,
        long TotalTokens,
        double Cost)
    {
        private static readonly string[] Input = { "input_tokens", "inputTokens", "prompt_tokens", "promptTokens" };
        private static readonly string[] Output = { "output_tokens", "outputTokens", "completion_tokens", "completionTokens" };
        private static readonly string[] CacheCreate = { "cache_creation_input_tokens", "cacheCreationInputTokens" };
        private static readonly string[] CacheRead = { "cache_read_input_tokens", "cacheReadInputTokens", "cached_tokens", "cachedTokens" };
        private static readonly string[] Reasoning = { "reasoning_tokens", "reasoningTokens" };
        private static readonly string[] Total = { "total_tokens", "totalTokens" };
        private static readonly string[] CostAliases = { "cost_usd", "costUsd", "total_cost_usd", "totalCostUsd", "cost" };

        public static UsageValues From(JsonElement element)
        {
            long input = FindLong(element, Input);
            long output = FindLong(element, Output);
            long cacheCreate = FindLong(element, CacheCreate);
            long cacheRead = FindLong(element, CacheRead);
            long reasoning = FindLong(element, Reasoning);
            long total = FindLong(element, Total);
            if (total == 0) total = input + output + cacheCreate + cacheRead + reasoning;
            return new UsageValues(input, output, cacheCreate, cacheRead, reasoning, total, FindDouble(element, CostAliases));
        }

        private static long FindLong(JsonElement element, IReadOnlyList<string> aliases)
        {
            foreach (JsonProperty property in element.EnumerateObject())
            {
                if (!aliases.Contains(property.Name, StringComparer.OrdinalIgnoreCase)) continue;
                if (property.Value.TryGetInt64(out long value)) return Math.Max(0, value);
                if (property.Value.ValueKind == JsonValueKind.String
                    && long.TryParse(property.Value.GetString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out value))
                    return Math.Max(0, value);
            }
            return 0;
        }

        private static double FindDouble(JsonElement element, IReadOnlyList<string> aliases)
        {
            foreach (JsonProperty property in element.EnumerateObject())
            {
                if (!aliases.Contains(property.Name, StringComparer.OrdinalIgnoreCase)) continue;
                if (property.Value.TryGetDouble(out double value)) return Math.Max(0, value);
                if (property.Value.ValueKind == JsonValueKind.String
                    && double.TryParse(property.Value.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out value))
                    return Math.Max(0, value);
            }
            return 0;
        }
    }
}
