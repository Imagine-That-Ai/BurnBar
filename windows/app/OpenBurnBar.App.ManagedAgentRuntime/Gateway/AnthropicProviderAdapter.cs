using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text;

namespace OpenBurnBar.App.ManagedAgentRuntime.Gateway;

/// <summary>
/// Wire adapter for the Anthropic Messages API. It handles bounded text, image,
/// and tool-call requests; unsupported shapes fail closed instead of being sent
/// as OpenAI JSON.
/// </summary>
public static class AnthropicProviderAdapter
{
    public const string ApiVersion = "2023-06-01";

    public static bool IsAnthropic(ModelRoute route) =>
        string.Equals(route.Vendor, "anthropic", StringComparison.OrdinalIgnoreCase);

    public static byte[] ToMessagesRequest(byte[] openAiBody, string model)
    {
        JsonObject source = ParseObject(openAiBody, "anthropic_request_invalid_json");
        bool streaming = ReadBool(source["stream"], "anthropic_stream_invalid");

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

        if (streaming)
        {
            target["stream"] = true;
        }

        CopyTools(source, target);
        CopyToolChoice(source, target);

        CopyIfPresent(source, target, "temperature");
        CopyIfPresent(source, target, "top_p");
        CopyIfPresent(source, target, "stop", "stop_sequences");
        return JsonSerializer.SerializeToUtf8Bytes(target);
    }

    public static bool IsStreamingRequest(byte[] openAiBody)
    {
        JsonObject source = ParseObject(openAiBody, "anthropic_request_invalid_json");
        return ReadBool(source["stream"], "anthropic_stream_invalid");
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

    /// <summary>
    /// Convert a bounded Anthropic SSE response into OpenAI chat-completion
    /// chunks. The executor intentionally buffers the bounded body, but keeps
    /// the event framing and terminal <c>[DONE]</c> marker for downstream
    /// consumers. A missing terminal message_stop fails closed.
    /// </summary>
    public static byte[] ToOpenAiEventStream(byte[] anthropicBody, string fallbackModel)
    {
        string payload = Encoding.UTF8.GetString(anthropicBody);
        var events = ParseEvents(payload);
        var output = new StringBuilder(payload.Length);
        string id = "anthropic-stream";
        string model = fallbackModel;
        long created = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        bool sawStop = false;
        bool emittedRole = false;

        foreach ((string Name, string Data) item in events)
        {
            if (string.Equals(item.Data, "[DONE]", StringComparison.Ordinal))
            {
                sawStop = true;
                continue;
            }

            JsonObject data = ParseObject(Encoding.UTF8.GetBytes(item.Data), "anthropic_sse_invalid_json");
            string type = ReadString(data["type"], "anthropic_sse_type_invalid") ?? item.Name;
            switch (type)
            {
                case "message_start":
                {
                    if (data["message"] is not JsonObject message)
                    {
                        throw new ProviderWireFormatException(502, "anthropic_sse_message_invalid");
                    }

                    id = ReadString(message["id"], "anthropic_sse_id_invalid") ?? id;
                    model = ReadString(message["model"], "anthropic_sse_model_invalid") ?? model;
                    if (!emittedRole)
                    {
                        output.Append(EncodeChunk(id, model, created, new JsonObject
                        {
                            ["role"] = "assistant",
                        }, finishReason: null));
                        emittedRole = true;
                    }
                    break;
                }
                case "content_block_start":
                {
                    if (data["content_block"] is not JsonObject block)
                    {
                        throw new ProviderWireFormatException(502, "anthropic_sse_content_block_invalid");
                    }

                    string blockType = ReadString(block["type"], "anthropic_sse_content_type_invalid") ?? string.Empty;
                    if (string.Equals(blockType, "tool_use", StringComparison.OrdinalIgnoreCase))
                    {
                        int index = ReadNonNegativeInt(data["index"], "anthropic_sse_index_invalid");
                        string toolId = RequiredString(block["id"], "anthropic_sse_tool_id_required");
                        string name = RequiredString(block["name"], "anthropic_sse_tool_name_required");
                        output.Append(EncodeChunk(id, model, created, new JsonObject
                        {
                            ["tool_calls"] = new JsonArray
                            {
                                new JsonObject
                                {
                                    ["index"] = index,
                                    ["id"] = toolId,
                                    ["type"] = "function",
                                    ["function"] = new JsonObject
                                    {
                                        ["name"] = name,
                                        ["arguments"] = string.Empty,
                                    },
                                },
                            },
                        }, finishReason: null));
                    }
                    break;
                }
                case "content_block_delta":
                {
                    if (data["delta"] is not JsonObject delta)
                    {
                        throw new ProviderWireFormatException(502, "anthropic_sse_delta_invalid");
                    }

                    string deltaType = ReadString(delta["type"], "anthropic_sse_delta_type_invalid") ?? string.Empty;
                    if (string.Equals(deltaType, "text_delta", StringComparison.OrdinalIgnoreCase))
                    {
                        output.Append(EncodeChunk(id, model, created, new JsonObject
                        {
                            ["content"] = RequiredString(delta["text"], "anthropic_sse_text_invalid"),
                        }, finishReason: null));
                    }
                    else if (string.Equals(deltaType, "input_json_delta", StringComparison.OrdinalIgnoreCase))
                    {
                        int index = ReadNonNegativeInt(data["index"], "anthropic_sse_index_invalid");
                        output.Append(EncodeChunk(id, model, created, new JsonObject
                        {
                            ["tool_calls"] = new JsonArray
                            {
                                new JsonObject
                                {
                                    ["index"] = index,
                                    ["function"] = new JsonObject
                                    {
                                        ["arguments"] = RequiredString(delta["partial_json"], "anthropic_sse_partial_json_invalid"),
                                    },
                                },
                            },
                        }, finishReason: null));
                    }
                    else
                    {
                        throw new ProviderWireFormatException(501, "anthropic_sse_delta_unsupported");
                    }
                    break;
                }
                case "message_delta":
                {
                    if (data["delta"] is not JsonObject delta)
                    {
                        throw new ProviderWireFormatException(502, "anthropic_sse_message_delta_invalid");
                    }

                    string finish = MapFinishReason(ReadString(delta["stop_reason"], "anthropic_sse_stop_reason_invalid"));
                    output.Append(EncodeChunk(id, model, created, new JsonObject(), finish));
                    break;
                }
                case "message_stop":
                    output.Append("data: [DONE]\n\n");
                    sawStop = true;
                    break;
                case "ping":
                case "content_block_stop":
                    break;
                case "error":
                    throw new ProviderWireFormatException(502, "anthropic_sse_provider_error");
                default:
                    throw new ProviderWireFormatException(501, "anthropic_sse_event_unsupported");
            }
        }

        if (!sawStop)
        {
            throw new ProviderWireFormatException(502, "anthropic_sse_missing_message_stop");
        }

        return Encoding.UTF8.GetBytes(output.ToString());
    }

    private static IReadOnlyList<(string Name, string Data)> ParseEvents(string payload)
    {
        var events = new List<(string Name, string Data)>();
        string? name = null;
        var data = new StringBuilder();

        void Flush()
        {
            if (data.Length == 0)
            {
                name = null;
                return;
            }

            events.Add((name ?? string.Empty, data.ToString()));
            name = null;
            data.Clear();
        }

        foreach (string line in payload.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n'))
        {
            if (line.Length == 0)
            {
                Flush();
            }
            else if (line.StartsWith("event:", StringComparison.Ordinal))
            {
                name = line[6..].Trim();
            }
            else if (line.StartsWith("data:", StringComparison.Ordinal))
            {
                if (data.Length > 0)
                {
                    data.Append('\n');
                }
                data.Append(line[5..].TrimStart());
            }
            else if (line[0] != ':')
            {
                throw new ProviderWireFormatException(502, "anthropic_sse_line_invalid");
            }
        }

        Flush();
        return events;
    }

    private static string EncodeChunk(
        string id,
        string model,
        long created,
        JsonObject delta,
        string? finishReason)
    {
        var choice = new JsonObject
        {
            ["index"] = 0,
            ["delta"] = delta,
            ["finish_reason"] = finishReason,
        };
        var chunk = new JsonObject
        {
            ["id"] = id,
            ["object"] = "chat.completion.chunk",
            ["created"] = created,
            ["model"] = model,
            ["choices"] = new JsonArray { choice },
        };
        return $"data: {chunk.ToJsonString()}\n\n";
    }

    private static int ReadNonNegativeInt(JsonNode? node, string error)
    {
        if (node is JsonValue value && value.TryGetValue<int>(out int result) && result >= 0)
        {
            return result;
        }

        throw new ProviderWireFormatException(502, error);
    }

    private static string MapFinishReason(string? reason) => reason switch
    {
        "max_tokens" => "length",
        "tool_use" => "tool_calls",
        _ => "stop",
    };

    private static JsonArray BuildMessageContent(JsonObject message, string role)
    {
        var blocks = new JsonArray();
        AppendOpenAiContentBlocks(message["content"], blocks);
        string text = TextContent(message["content"]);

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

    private static void AppendOpenAiContentBlocks(JsonNode? node, JsonArray blocks)
    {
        if (node is null)
        {
            return;
        }

        if (node is JsonValue value && value.TryGetValue<string>(out string? plainText))
        {
            if (!string.IsNullOrWhiteSpace(plainText))
            {
                blocks.Add(new JsonObject { ["type"] = "text", ["text"] = plainText });
            }

            return;
        }

        if (node is not JsonArray content)
        {
            throw new ProviderWireFormatException(400, "anthropic_content_invalid");
        }

        foreach (JsonNode? item in content)
        {
            if (item is not JsonObject block)
            {
                throw new ProviderWireFormatException(400, "anthropic_content_block_invalid");
            }

            string type = RequiredString(block["type"], "anthropic_content_type_required");
            if (string.Equals(type, "text", StringComparison.OrdinalIgnoreCase))
            {
                string text = RequiredString(block["text"], "anthropic_content_text_required");
                blocks.Add(new JsonObject { ["type"] = "text", ["text"] = text });
                continue;
            }

            if (string.Equals(type, "image_url", StringComparison.OrdinalIgnoreCase))
            {
                blocks.Add(ConvertImageBlock(block));
                continue;
            }

            throw new ProviderWireFormatException(400, "anthropic_content_block_unsupported");
        }
    }

    private static JsonObject ConvertImageBlock(JsonObject block)
    {
        if (block["image_url"] is not JsonObject image)
        {
            throw new ProviderWireFormatException(400, "anthropic_image_url_required");
        }

        string url = RequiredString(image["url"], "anthropic_image_url_required");
        if (url.StartsWith("data:", StringComparison.OrdinalIgnoreCase))
        {
            int comma = url.IndexOf(',');
            if (comma <= 5)
            {
                throw new ProviderWireFormatException(400, "anthropic_image_data_url_invalid");
            }

            string metadata = url[5..comma];
            string[] metadataParts = metadata.Split(';', StringSplitOptions.RemoveEmptyEntries);
            string mediaType = metadataParts.Length > 0 ? metadataParts[0] : string.Empty;
            if (!mediaType.StartsWith("image/", StringComparison.OrdinalIgnoreCase)
                || !Array.Exists(metadataParts, part => string.Equals(part, "base64", StringComparison.OrdinalIgnoreCase)))
            {
                throw new ProviderWireFormatException(400, "anthropic_image_data_url_invalid");
            }

            string encoded = url[(comma + 1)..];
            try
            {
                if (Convert.FromBase64String(encoded).Length > 8 * 1024 * 1024)
                {
                    throw new ProviderWireFormatException(413, "anthropic_image_too_large");
                }
            }
            catch (FormatException error)
            {
                throw new ProviderWireFormatException(400, "anthropic_image_base64_invalid", error);
            }

            return new JsonObject
            {
                ["type"] = "image",
                ["source"] = new JsonObject
                {
                    ["type"] = "base64",
                    ["media_type"] = mediaType,
                    ["data"] = encoded,
                },
            };
        }

        if (!Uri.TryCreate(url, UriKind.Absolute, out Uri? uri)
            || !string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)
            || uri.UserInfo.Length > 0
            || url.Length > 4096)
        {
            throw new ProviderWireFormatException(400, "anthropic_image_url_invalid");
        }

        return new JsonObject
        {
            ["type"] = "image",
            ["source"] = new JsonObject
            {
                ["type"] = "url",
                ["url"] = url,
            },
        };
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
