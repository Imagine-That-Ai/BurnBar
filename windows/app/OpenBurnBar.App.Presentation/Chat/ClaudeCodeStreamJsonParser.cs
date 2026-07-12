using System;
using System.Collections.Generic;
using System.Text.Json;

namespace OpenBurnBar.App.Presentation.Chat;

/// <summary>
/// Portable peer of Mac <c>ClaudeCodeStreamJSONParser</c>
/// (<c>AgentLens/Services/CLIBridge/CLIStreamParsers.swift</c>).
/// Parses one NDJSON line from Claude Code <c>stream-json</c> into ordered
/// <see cref="ChatStreamEvent"/> values for the chat state machine.
/// </summary>
public static class ClaudeCodeStreamJsonParser
{
    /// <summary>Parse one NDJSON line; malformed lines yield an empty list.</summary>
    public static IReadOnlyList<ChatStreamEvent> EventsFromLine(string line)
    {
        if (string.IsNullOrWhiteSpace(line))
        {
            return Array.Empty<ChatStreamEvent>();
        }

        try
        {
            using JsonDocument document = JsonDocument.Parse(line);
            JsonElement root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return Array.Empty<ChatStreamEvent>();
            }

            List<ChatStreamEvent> fromMessage = EventsFromMessageContent(root);
            if (fromMessage.Count > 0)
            {
                return fromMessage;
            }

            string? type = GetString(root, "type");
            if (type == "tool_use" && TryToolUse(root, out ChatStreamEvent toolUse))
            {
                return new[] { toolUse };
            }

            if (type == "tool_result" && TryToolResult(root, out ChatStreamEvent toolResult))
            {
                return new[] { toolResult };
            }

            string? text = ExtractStreamJsonText(root);
            if (!string.IsNullOrEmpty(text))
            {
                return new ChatStreamEvent[] { new ChatStreamEvent.Text(text) };
            }

            ChatStreamEvent? usage = TryUsage(root);
            if (usage is not null)
            {
                return new[] { usage };
            }

            return Array.Empty<ChatStreamEvent>();
        }
        catch (JsonException)
        {
            return Array.Empty<ChatStreamEvent>();
        }
    }

    public static IReadOnlyList<ChatStreamEvent> EventsFromLineStrict(string line)
    {
        if (string.IsNullOrWhiteSpace(line))
        {
            return Array.Empty<ChatStreamEvent>();
        }

        try
        {
            using JsonDocument document = JsonDocument.Parse(line);
            JsonElement root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return new ChatStreamEvent[]
                {
                    new ChatStreamEvent.StreamFailure(
                        ChatFailureKind.MalformedStream,
                        "The chat backend returned a non-object stream record."),
                };
            }

            if (TryOpenBurnBarStreamFailure(root, out ChatStreamEvent.StreamFailure? failure) && failure is not null)
            {
                return new ChatStreamEvent[] { failure };
            }
        }
        catch (JsonException ex)
        {
            return new ChatStreamEvent[]
            {
                new ChatStreamEvent.StreamFailure(
                    ChatFailureKind.MalformedStream,
                    "The chat backend returned malformed stream JSON: " + ex.Message),
            };
        }

        IReadOnlyList<ChatStreamEvent> events = EventsFromLine(line);
        if (events.Count == 0)
        {
            return new ChatStreamEvent[]
            {
                new ChatStreamEvent.StreamFailure(
                    ChatFailureKind.MalformedStream,
                    "The chat backend returned an unsupported stream record."),
            };
        }

        return events;
    }

    private static List<ChatStreamEvent> EventsFromMessageContent(JsonElement root)
    {
        var outEvents = new List<ChatStreamEvent>();
        if (!root.TryGetProperty("message", out JsonElement message)
            || message.ValueKind != JsonValueKind.Object
            || !message.TryGetProperty("content", out JsonElement content)
            || content.ValueKind != JsonValueKind.Array)
        {
            return outEvents;
        }

        foreach (JsonElement block in content.EnumerateArray())
        {
            if (block.ValueKind != JsonValueKind.Object)
            {
                continue;
            }

            string kind = GetString(block, "type") ?? string.Empty;
            if (kind == "text")
            {
                string? text = GetString(block, "text");
                if (!string.IsNullOrEmpty(text))
                {
                    outEvents.Add(new ChatStreamEvent.Text(text));
                }
            }
            else if (kind == "tool_use" && TryToolUse(block, out ChatStreamEvent toolUse))
            {
                outEvents.Add(toolUse);
            }
            else if (kind == "tool_result" && TryToolResult(block, out ChatStreamEvent toolResult))
            {
                outEvents.Add(toolResult);
            }
        }

        return outEvents;
    }

    private static bool TryToolUse(JsonElement obj, out ChatStreamEvent evt)
    {
        evt = null!;
        string? name = GetString(obj, "name") ?? GetString(obj, "tool");
        if (string.IsNullOrEmpty(name))
        {
            return false;
        }

        string? detail = null;
        if (obj.TryGetProperty("input", out JsonElement input) && input.ValueKind == JsonValueKind.Object)
        {
            detail = ToolInputSummary(input);
        }

        evt = new ChatStreamEvent.ToolUse(name, detail);
        return true;
    }

    private static bool TryToolResult(JsonElement obj, out ChatStreamEvent evt)
    {
        string name = GetString(obj, "name")
            ?? GetString(obj, "tool")
            ?? GetString(obj, "tool_name")
            ?? GetString(obj, "tool_use_id")
            ?? "Tool result";
        evt = new ChatStreamEvent.ToolResult(name, ToolResultSummary(obj));
        return true;
    }

    private static string? ToolInputSummary(JsonElement input)
    {
        string? path = GetString(input, "path") ?? GetString(input, "file_path");
        if (!string.IsNullOrEmpty(path))
        {
            return path;
        }

        string? command = GetString(input, "command");
        if (!string.IsNullOrEmpty(command))
        {
            return command.Length <= 160 ? command : command[..160];
        }

        string? pattern = GetString(input, "pattern");
        if (!string.IsNullOrEmpty(pattern))
        {
            return pattern;
        }

        string? query = GetString(input, "query");
        if (!string.IsNullOrEmpty(query))
        {
            return query.Length <= 120 ? query : query[..120];
        }

        return null;
    }

    private static string? ToolResultSummary(JsonElement obj)
    {
        string? content = GetString(obj, "content");
        if (!string.IsNullOrEmpty(content))
        {
            return content.Length <= 400 ? content : content[..400];
        }

        string? text = GetString(obj, "text") ?? GetString(obj, "output");
        if (!string.IsNullOrEmpty(text))
        {
            return text.Length <= 400 ? text : text[..400];
        }

        if (obj.TryGetProperty("content", out JsonElement arr) && arr.ValueKind == JsonValueKind.Array)
        {
            var parts = new List<string>();
            foreach (JsonElement block in arr.EnumerateArray())
            {
                if (block.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }

                string? part = GetString(block, "text") ?? GetString(block, "content");
                if (!string.IsNullOrEmpty(part))
                {
                    parts.Add(part);
                }
            }

            if (parts.Count == 0)
            {
                return null;
            }

            string joined = string.Join("\n", parts).Trim();
            return joined.Length <= 400 ? joined : joined[..400];
        }

        return null;
    }

    private static string? ExtractStreamJsonText(JsonElement obj)
    {
        if (obj.TryGetProperty("delta", out JsonElement delta) && delta.ValueKind == JsonValueKind.Object)
        {
            string? text = GetString(delta, "text");
            if (!string.IsNullOrEmpty(text))
            {
                return text;
            }

            if (delta.TryGetProperty("delta", out JsonElement inner) && inner.ValueKind == JsonValueKind.Object)
            {
                text = GetString(inner, "text");
                if (!string.IsNullOrEmpty(text))
                {
                    return text;
                }
            }
        }

        if (obj.TryGetProperty("message", out JsonElement message)
            && message.ValueKind == JsonValueKind.Object
            && message.TryGetProperty("content", out JsonElement content)
            && content.ValueKind == JsonValueKind.Array)
        {
            foreach (JsonElement block in content.EnumerateArray())
            {
                if (block.ValueKind == JsonValueKind.Object
                    && GetString(block, "type") == "text")
                {
                    string? text = GetString(block, "text");
                    if (!string.IsNullOrEmpty(text))
                    {
                        return text;
                    }
                }
            }
        }

        if (obj.TryGetProperty("event", out JsonElement evt)
            && evt.ValueKind == JsonValueKind.Object
            && evt.TryGetProperty("delta", out JsonElement evtDelta)
            && evtDelta.ValueKind == JsonValueKind.Object)
        {
            return GetString(evtDelta, "text");
        }

        return null;
    }

    private static ChatStreamEvent? TryUsage(JsonElement root)
    {
        if (!root.TryGetProperty("usage", out JsonElement usage) && !root.TryGetProperty("message", out JsonElement message))
        {
            return null;
        }

        if (root.TryGetProperty("message", out message)
            && message.ValueKind == JsonValueKind.Object
            && message.TryGetProperty("usage", out JsonElement messageUsage))
        {
            usage = messageUsage;
        }

        if (usage.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        int input = GetInt(usage, "input_tokens") ?? GetInt(usage, "inputTokens") ?? 0;
        int output = GetInt(usage, "output_tokens") ?? GetInt(usage, "outputTokens") ?? 0;
        int cacheCreate = GetInt(usage, "cache_creation_input_tokens") ?? GetInt(usage, "cacheCreationTokens") ?? 0;
        int cacheRead = GetInt(usage, "cache_read_input_tokens") ?? GetInt(usage, "cacheReadTokens") ?? 0;
        int reasoning = GetInt(usage, "reasoning_tokens") ?? GetInt(usage, "reasoningTokens") ?? 0;
        if (input == 0 && output == 0 && cacheCreate == 0 && cacheRead == 0 && reasoning == 0)
        {
            return null;
        }

        return new ChatStreamEvent.Usage(
            new CliUsageSnapshot(input, output, cacheCreate, cacheRead, reasoning));
    }

    private static bool TryOpenBurnBarStreamFailure(JsonElement root, out ChatStreamEvent.StreamFailure? failure)
    {
        failure = null;
        if (!root.TryGetProperty("openburnbar_stream_error", out JsonElement error)
            || error.ValueKind != JsonValueKind.Object)
        {
            return false;
        }

        string? kindText = GetString(error, "kind");
        string? message = GetString(error, "message");
        if (!Enum.TryParse(kindText, ignoreCase: true, out ChatFailureKind kind))
        {
            kind = ChatFailureKind.StreamError;
        }

        failure = new ChatStreamEvent.StreamFailure(
            kind,
            string.IsNullOrWhiteSpace(message) ? "The chat backend failed." : message);
        return true;
    }

    private static string? GetString(JsonElement obj, string name)
    {
        if (!obj.TryGetProperty(name, out JsonElement value))
        {
            return null;
        }

        return value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    }

    private static int? GetInt(JsonElement obj, string name)
    {
        if (!obj.TryGetProperty(name, out JsonElement value))
        {
            return null;
        }

        return value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out int n) ? n : null;
    }
}
