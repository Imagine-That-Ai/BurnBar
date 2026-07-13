using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace OpenBurnBar.App.ManagedAgentRuntime.Gateway;

/// <summary>
/// Wire adapter for the Anthropic Messages API. It handles bounded, non-streaming
/// text and tool-call requests; streaming remains an explicit unsupported shape
/// until the gateway has a true event-stream bridge. Unsupported shapes fail
/// closed instead of being sent as OpenAI JSON.
/// </summary>
public static class AnthropicProviderAdapter
{
    public const string ApiVersion = "2023-06-01";

    public static bool IsAnthropic(ModelRoute route) =>
        string.Equals(route.Vendor, "anthropic", StringComparison.OrdinalIgnoreCase);

    public static byte[] ToMessagesRequest(byte[] openAiBody, string model)
    {
        JsonObject source = ParseObject(openAiBody, "anthropic_request_invalid_json");
        if (ReadBool(source["stream"], "anthropic_stream_invalid"))
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

            string role = (ReadString(message["role"], "anthropic_role_invalid") ?? "user")
                .Trim()
                .ToLowerInvariant();
            if (role is "system" or "developer")
            {
                string content = TextContent(message["content"]);
                if (!string.IsNullOrWhiteSpace(content))
                {
                    systemParts.Add(content);
                }
                continue;
            }

            JsonArray contentBlocks = BuildMessageContent(message, role);
            if (contentBlocks.Count == 0)
            {
                continue;
            }

            messages.Add(new JsonObject
            {
                ["role"] = role == "assistant" ? "assistant" : "user",
                ["content"] = contentBlocks,
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

        CopyTools(source, target);
        CopyToolChoice(source, target);

        CopyIfPresent(source, target, "temperature");
        CopyIfPresent(source, target, "top_p");
        CopyIfPresent(source, target, "stop", "stop_sequences");
        return JsonSerializer.SerializeToUtf8Bytes(target);
    }

    public static byte[] ToOpenAiResponse(byte[] anthropicBody, string fallbackModel)
    {
        JsonObject source = ParseObject(anthropicBody, "anthropic_response_invalid_json");
        (string text, JsonArray? toolCalls) = ReadResponseContent(source["content"]);
        string model = ReadString(source["model"], "anthropic_model_invalid") ?? fallbackModel;
        string finishReason = ReadString(source["stop_reason"], "anthropic_stop_reason_invalid") switch
        {
            "max_tokens" => "length",
            "tool_use" => "tool_calls",
            _ => "stop",
        };

        JsonObject? usage = source["usage"] as JsonObject;
        int promptTokens = ReadPositiveInt(usage, "input_tokens") ?? 0;
        int completionTokens = ReadPositiveInt(usage, "output_tokens") ?? 0;
        var message = new JsonObject
        {
            ["role"] = "assistant",
            ["content"] = string.IsNullOrEmpty(text) && toolCalls is not null ? null : text,
        };
        if (toolCalls is not null)
        {
            message["tool_calls"] = toolCalls;
        }

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
                    ["message"] = message,
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

    private static JsonArray BuildMessageContent(JsonObject message, string role)
    {
        var blocks = new JsonArray();
        string text = TextContent(message["content"]);
        if (!string.IsNullOrWhiteSpace(text))
        {
            blocks.Add(new JsonObject
            {
                ["type"] = "text",
                ["text"] = text,
            });
        }

        if (role == "assistant")
        {
            AppendAssistantToolCalls(message, blocks);
        }
        else if (role == "tool")
        {
            string toolUseId = RequiredString(message["tool_call_id"], "anthropic_tool_call_id_required");
            blocks.Add(new JsonObject
            {
                ["type"] = "tool_result",
                ["tool_use_id"] = toolUseId,
                ["content"] = text,
            });
        }

        return blocks;
    }

    private static void AppendAssistantToolCalls(JsonObject message, JsonArray blocks)
    {
        if (message["tool_calls"] is not JsonArray calls)
        {
            return;
        }

        foreach (JsonNode? callNode in calls)
        {
            if (callNode is not JsonObject call)
            {
                throw new ProviderWireFormatException(400, "anthropic_tool_call_invalid");
            }

            string id = RequiredString(call["id"], "anthropic_tool_call_id_required");
            string type = ReadString(call["type"], "anthropic_tool_call_type_invalid") ?? "function";
            if (!string.Equals(type, "function", StringComparison.OrdinalIgnoreCase))
            {
                throw new ProviderWireFormatException(400, "anthropic_tool_call_type_invalid");
            }

            if (call["function"] is not JsonObject function)
            {
                throw new ProviderWireFormatException(400, "anthropic_tool_function_required");
            }

            string name = RequiredString(function["name"], "anthropic_tool_name_required");
            string arguments = ReadString(function["arguments"], "anthropic_tool_arguments_invalid") ?? "{}";
            JsonNode input = ParseToolArguments(arguments);
            blocks.Add(new JsonObject
            {
                ["type"] = "tool_use",
                ["id"] = id,
                ["name"] = name,
                ["input"] = input,
            });
        }
    }

    private static JsonNode ParseToolArguments(string arguments)
    {
        try
        {
            return JsonNode.Parse(arguments) ?? throw new ProviderWireFormatException(400, "anthropic_tool_arguments_invalid");
        }
        catch (JsonException exception)
        {
            throw new ProviderWireFormatException(400, "anthropic_tool_arguments_invalid", exception);
        }
    }

    private static void CopyTools(JsonObject source, JsonObject target)
    {
        if (source["tools"] is not JsonArray sourceTools)
        {
            return;
        }

        var tools = new JsonArray();
        foreach (JsonNode? node in sourceTools)
        {
            if (node is not JsonObject tool
                || !string.Equals(ReadString(tool["type"], "anthropic_tool_type_invalid") ?? "function", "function", StringComparison.OrdinalIgnoreCase)
                || tool["function"] is not JsonObject function)
            {
                throw new ProviderWireFormatException(400, "anthropic_tool_invalid");
            }

            string name = RequiredString(function["name"], "anthropic_tool_name_required");
            var converted = new JsonObject
            {
                ["name"] = name,
                ["input_schema"] = function["parameters"]?.DeepClone() ?? new JsonObject(),
            };
            string? description = ReadString(function["description"], "anthropic_tool_description_invalid");
            if (!string.IsNullOrWhiteSpace(description))
            {
                converted["description"] = description;
            }

            tools.Add(converted);
        }

        target["tools"] = tools;
    }

    private static void CopyToolChoice(JsonObject source, JsonObject target)
    {
        JsonNode? choice = source["tool_choice"];
        if (choice is null)
        {
            return;
        }

        if (choice is JsonValue value && value.TryGetValue<string>(out string? text))
        {
            target["tool_choice"] = text?.ToLowerInvariant() switch
            {
                "auto" => new JsonObject { ["type"] = "auto" },
                "required" => new JsonObject { ["type"] = "any" },
                "none" => null,
                _ => throw new ProviderWireFormatException(400, "anthropic_tool_choice_invalid"),
            };
            return;
        }

        if (choice is not JsonObject selected
            || !string.Equals(ReadString(selected["type"], "anthropic_tool_choice_invalid"), "function", StringComparison.OrdinalIgnoreCase)
            || selected["function"] is not JsonObject function)
        {
            throw new ProviderWireFormatException(400, "anthropic_tool_choice_invalid");
        }

        target["tool_choice"] = new JsonObject
        {
            ["type"] = "tool",
            ["name"] = RequiredString(function["name"], "anthropic_tool_name_required"),
        };
    }

    private static (string Text, JsonArray? ToolCalls) ReadResponseContent(JsonNode? node)
    {
        if (node is not JsonArray blocks)
        {
            return (TextContent(node), null);
        }

        var texts = new List<string>();
        JsonArray? toolCalls = null;
        foreach (JsonNode? blockNode in blocks)
        {
            if (blockNode is not JsonObject block)
            {
                throw new ProviderWireFormatException(502, "anthropic_response_block_invalid");
            }

            string type = ReadString(block["type"], "anthropic_response_block_type_invalid") ?? string.Empty;
            if (string.Equals(type, "text", StringComparison.OrdinalIgnoreCase))
            {
                string text = RequiredString(block["text"], "anthropic_response_text_invalid");
                texts.Add(text);
                continue;
            }

            if (string.Equals(type, "tool_use", StringComparison.OrdinalIgnoreCase))
            {
                string id = RequiredString(block["id"], "anthropic_response_tool_id_required");
                string name = RequiredString(block["name"], "anthropic_response_tool_name_required");
                JsonNode input = block["input"]?.DeepClone()
                    ?? throw new ProviderWireFormatException(502, "anthropic_response_tool_input_required");
                toolCalls ??= new JsonArray();
                toolCalls.Add(new JsonObject
                {
                    ["id"] = id,
                    ["type"] = "function",
                    ["function"] = new JsonObject
                    {
                        ["name"] = name,
                        ["arguments"] = input.ToJsonString(),
                    },
                });
            }
        }

        return (string.Join("\n", texts), toolCalls);
    }

    private static string RequiredString(JsonNode? node, string error)
    {
        string? value = ReadString(node, error);
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new ProviderWireFormatException(400, error);
        }

        return value;
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

        if (node is JsonValue)
        {
            throw new ProviderWireFormatException(400, "anthropic_content_invalid");
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

            if (string.Equals(ReadString(block["type"], "anthropic_content_type_invalid"), "text", StringComparison.OrdinalIgnoreCase)
                && block["text"] is JsonValue blockText
                && blockText.TryGetValue<string>(out string? textValue)
                && !string.IsNullOrWhiteSpace(textValue))
            {
                parts.Add(textValue);
            }
        }

        return string.Join("\n", parts);
    }

    private static string? ReadString(JsonNode? node, string error)
    {
        if (node is null)
        {
            return null;
        }

        if (node is JsonValue value && value.TryGetValue<string>(out string? result))
        {
            return result;
        }

        throw new ProviderWireFormatException(400, error);
    }

    private static bool ReadBool(JsonNode? node, string error)
    {
        if (node is null)
        {
            return false;
        }

        if (node is JsonValue value && value.TryGetValue<bool>(out bool result))
        {
            return result;
        }

        throw new ProviderWireFormatException(400, error);
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
