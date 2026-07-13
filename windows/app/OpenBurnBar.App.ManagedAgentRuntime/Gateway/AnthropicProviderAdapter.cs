using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace OpenBurnBar.App.ManagedAgentRuntime.Gateway;

/// <summary>
/// Narrow wire adapter for the Anthropic Messages API. It deliberately handles
/// text-only, non-streaming requests until the full tool/SSE bridge is ported;
/// unsupported shapes fail closed instead of being sent as OpenAI JSON.
/// </summary>
public static class AnthropicProviderAdapter
{
    public const string ApiVersion = "2023-06-01";

    public static bool IsAnthropic(ModelRoute route) =>
        string.Equals(route.Vendor, "anthropic", StringComparison.OrdinalIgnoreCase);

    public static byte[] ToMessagesRequest(byte[] openAiBody, string model)
    {
        JsonObject source = ParseObject(openAiBody, "anthropic_request_invalid_json");
        if (source["stream"]?.GetValue<bool>() == true)
        {
            throw new ProviderWireFormatException(501, "anthropic_streaming_not_supported");
        }

        JsonArray? sourceMessages = source["messages"] as JsonArray;
        if (sourceMessages is null || sourceMessages.Count == 0)
        {
            throw new ProviderWireFormatException(400, "anthropic_messages_required");
        }

        var systemParts = new List<string>();
        var messages = new JsonArray();
        foreach (JsonNode? node in sourceMessages)
        {
            if (node is not JsonObject message)
            {
                throw new ProviderWireFormatException(400, "anthropic_message_invalid");
            }

            string role = message["role"]?.GetValue<string>()?.Trim().ToLowerInvariant() ?? "user";
            string content = TextContent(message["content"]);
            if (string.IsNullOrWhiteSpace(content))
            {
                continue;
            }

            if (role is "system" or "developer")
            {
                systemParts.Add(content);
                continue;
            }

            messages.Add(new JsonObject
            {
                ["role"] = role == "assistant" ? "assistant" : "user",
                ["content"] = new JsonArray
                {
                    new JsonObject { ["type"] = "text", ["text"] = content },
                },
            });
        }

        if (messages.Count == 0)
        {
            throw new ProviderWireFormatException(400, "anthropic_messages_empty");
        }

        int maxTokens = ReadPositiveInt(source, "max_tokens")
            ?? ReadPositiveInt(source, "max_completion_tokens")
            ?? 1024;
        var target = new JsonObject
        {
            ["model"] = model,
            ["max_tokens"] = maxTokens,
            ["messages"] = messages,
        };
        if (systemParts.Count > 0)
        {
            target["system"] = string.Join("\n\n", systemParts);
        }

        CopyIfPresent(source, target, "temperature");
        CopyIfPresent(source, target, "top_p");
        CopyIfPresent(source, target, "stop", "stop_sequences");
        return JsonSerializer.SerializeToUtf8Bytes(target);
    }

    public static byte[] ToOpenAiResponse(byte[] anthropicBody, string fallbackModel)
    {
        JsonObject source = ParseObject(anthropicBody, "anthropic_response_invalid_json");
        string text = TextContent(source["content"]);
        string model = source["model"]?.GetValue<string>() ?? fallbackModel;
        string finishReason = source["stop_reason"]?.GetValue<string>() switch
        {
            "max_tokens" => "length",
            "tool_use" => "tool_calls",
            _ => "stop",
        };

        JsonObject? usage = source["usage"] as JsonObject;
        int promptTokens = ReadPositiveInt(usage, "input_tokens") ?? 0;
        int completionTokens = ReadPositiveInt(usage, "output_tokens") ?? 0;
        var response = new JsonObject
        {
            ["id"] = source["id"]?.GetValue<string>() ?? "anthropic-response",
            ["object"] = "chat.completion",
            ["created"] = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
            ["model"] = model,
            ["choices"] = new JsonArray
            {
                new JsonObject
                {
                    ["index"] = 0,
                    ["message"] = new JsonObject
                    {
                        ["role"] = "assistant",
                        ["content"] = text,
                    },
                    ["finish_reason"] = finishReason,
                },
            },
            ["usage"] = new JsonObject
            {
                ["prompt_tokens"] = promptTokens,
                ["completion_tokens"] = completionTokens,
                ["total_tokens"] = promptTokens + completionTokens,
            },
        };
        return JsonSerializer.SerializeToUtf8Bytes(response);
    }

    private static JsonObject ParseObject(byte[] body, string error)
    {
        try
        {
            return JsonNode.Parse(body) as JsonObject
                ?? throw new ProviderWireFormatException(400, error);
        }
        catch (JsonException exception)
        {
            throw new ProviderWireFormatException(400, error, exception);
        }
    }

    private static string TextContent(JsonNode? node)
    {
        if (node is JsonValue value && value.TryGetValue<string>(out string? text))
        {
            return text ?? string.Empty;
        }

        if (node is not JsonArray blocks)
        {
            return string.Empty;
        }

        var parts = new List<string>();
        foreach (JsonNode? blockNode in blocks)
        {
            if (blockNode is not JsonObject block)
            {
                continue;
            }

            if (string.Equals(block["type"]?.GetValue<string>(), "text", StringComparison.OrdinalIgnoreCase)
                && block["text"] is JsonValue blockText
                && blockText.TryGetValue<string>(out string? textValue)
                && !string.IsNullOrWhiteSpace(textValue))
            {
                parts.Add(textValue);
            }
        }

        return string.Join("\n", parts);
    }

    private static int? ReadPositiveInt(JsonObject? source, string property)
    {
        if (source is null || source[property] is not JsonValue value || !value.TryGetValue<int>(out int result))
        {
            return null;
        }

        return result > 0 ? result : null;
    }

    private static void CopyIfPresent(JsonObject source, JsonObject target, string sourceName, string? targetName = null)
    {
        if (source[sourceName] is JsonNode value)
        {
            target[targetName ?? sourceName] = value.DeepClone();
        }
    }
}

internal sealed class ProviderWireFormatException : Exception
{
    public ProviderWireFormatException(int statusCode, string message, Exception? innerException = null)
        : base(message, innerException)
    {
        StatusCode = statusCode;
    }

    public int StatusCode { get; }
}
