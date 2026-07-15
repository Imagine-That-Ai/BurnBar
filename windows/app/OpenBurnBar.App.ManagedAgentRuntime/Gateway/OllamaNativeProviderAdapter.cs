using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace OpenBurnBar.App.ManagedAgentRuntime.Gateway;

/// <summary>OpenAI-compatible request/response bridge for Ollama's native <c>/api/chat</c> wire.</summary>
public static class OllamaNativeProviderAdapter
{
    public static bool IsNative(ModelRoute route)
    {
        ArgumentNullException.ThrowIfNull(route);
        if (route.Endpoint is null
            || !(string.Equals(route.Vendor, "ollama", StringComparison.OrdinalIgnoreCase)
                || string.Equals(route.Vendor, "ollama-local", StringComparison.OrdinalIgnoreCase)))
        {
            return false;
        }

        string path = route.Endpoint.AbsolutePath.TrimEnd('/').ToLowerInvariant();
        return !path.EndsWith("/v1", StringComparison.Ordinal)
            && !path.Contains("/v1/", StringComparison.Ordinal);
    }

    public static Uri ChatEndpoint(Uri baseUri)
    {
        ArgumentNullException.ThrowIfNull(baseUri);
        string path = baseUri.AbsolutePath.Trim('/').ToLowerInvariant();
        if (path == "api/chat" || path.EndsWith("/api/chat", StringComparison.Ordinal))
        {
            return baseUri;
        }

        string suffix = path == "api" || path.EndsWith("/api", StringComparison.Ordinal)
            ? "chat"
            : "api/chat";
        return new Uri(baseUri.ToString().TrimEnd('/') + "/" + suffix, UriKind.Absolute);
    }

    public static (byte[] Body, bool StreamRequested) ToNativeRequest(byte[] openAiBody, string model)
    {
        JsonObject source = ParseObject(openAiBody, 400, "ollama_request_invalid_json");
        bool stream = ReadBool(source["stream"], "ollama_stream_invalid");
        source["model"] = model;
        source["stream"] = stream;

        if (Take(source, "response_format") is JsonObject responseFormat)
        {
            string? type = ReadOptionalString(responseFormat["type"]);
            if (string.Equals(type, "json_object", StringComparison.Ordinal))
            {
                source["format"] = "json";
            }
            else if (responseFormat["json_schema"] is JsonObject schemaContainer
                && schemaContainer["schema"] is JsonNode schema)
            {
                source["format"] = schema.DeepClone();
            }
        }

        JsonObject options = Take(source, "options") as JsonObject ?? new JsonObject();
        Move(source, options, "max_completion_tokens", "num_predict");
        Move(source, options, "max_tokens", "num_predict");
        Move(source, options, "temperature", "temperature");
        Move(source, options, "top_p", "top_p");
        if (options.Count > 0)
        {
            source["options"] = options;
        }

        if (Take(source, "reasoning") is JsonObject reasoning)
        {
            ApplyThinkValue(ReadOptionalString(reasoning["effort"]), source);
        }
        ApplyThinkValue(ReadOptionalString(Take(source, "reasoning_effort")), source);

        foreach (string key in new[]
        {
            "n", "user", "logit_bias", "presence_penalty", "frequency_penalty",
            "stream_options", "tool_choice",
        })
        {
            source.Remove(key);
        }

        NormalizeMessages(source);
        return (JsonSerializer.SerializeToUtf8Bytes(source), stream);
    }

    public static ModelCompletionResult ToOpenAiResponse(
        byte[] nativeBody,
        string model,
        bool streamRequested)
    {
        try
        {
            return streamRequested
                ? ConvertStream(nativeBody, model)
                : ConvertBuffered(nativeBody, model);
        }
        catch (ProviderWireFormatException)
        {
            throw;
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException)
        {
            throw new ProviderWireFormatException(502, "ollama_response_invalid", error);
        }
    }

    private static ModelCompletionResult ConvertBuffered(byte[] body, string model)
    {
        JsonObject response = ParseObject(body, 502, "ollama_response_invalid");
        ValidateResponse(response, model);
        JsonObject message = OpenAiMessage(response);
        bool hasToolCalls = message["tool_calls"] is JsonArray calls && calls.Count > 0;
        var target = new JsonObject
        {
            ["id"] = "chatcmpl-" + Guid.NewGuid().ToString("N"),
            ["object"] = "chat.completion",
            ["created"] = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
            ["model"] = ReadOptionalString(response["model"]) ?? model,
            ["choices"] = new JsonArray
            {
                new JsonObject
                {
                    ["index"] = 0,
                    ["message"] = message,
                    ["finish_reason"] = FinishReason(ReadOptionalString(response["done_reason"]), hasToolCalls),
                },
            },
            ["usage"] = Usage(response),
        };
        return new ModelCompletionResult(
            200,
            JsonSerializer.SerializeToUtf8Bytes(target),
            "application/json",
            true);
    }

    private static ModelCompletionResult ConvertStream(byte[] body, string model)
    {
        string id = "chatcmpl-" + Guid.NewGuid().ToString("N");
        long created = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var output = new StringBuilder();
        JsonObject? finalResponse = null;
        bool sawDone = false;
        bool streamedToolCalls = false;

        foreach (string line in Encoding.UTF8.GetString(body)
                     .Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            JsonObject response = ParseObject(
                Encoding.UTF8.GetBytes(line.Trim()),
                502,
                "ollama_stream_event_invalid");
            finalResponse = response;
            JsonObject? nativeMessage = response["message"] as JsonObject;
            string content = ReadOptionalString(nativeMessage?["content"]) ?? string.Empty;
            if (content.Length > 0)
            {
                AppendEvent(output, StreamChunk(id, created, model, content, null, null, null));
            }

            JsonArray? toolCalls = OpenAiToolCalls(nativeMessage, includeIndex: true);
            if (toolCalls is { Count: > 0 })
            {
                streamedToolCalls = true;
                AppendEvent(output, StreamChunk(id, created, model, null, toolCalls, null, null));
            }

            if (ReadOptionalBool(response["done"]) == true)
            {
                sawDone = true;
                AppendEvent(output, StreamChunk(
                    id,
                    created,
                    model,
                    null,
                    null,
                    FinishReason(ReadOptionalString(response["done_reason"]), streamedToolCalls),
                    Usage(response)));
            }
        }

        if (!sawDone || finalResponse is null)
        {
            throw new ProviderWireFormatException(502, "ollama_stream_missing_done");
        }

        output.Append("data: [DONE]\n\n");
        return new ModelCompletionResult(
            200,
            Encoding.UTF8.GetBytes(output.ToString()),
            "text/event-stream",
            true);
    }

    private static JsonObject StreamChunk(
        string id,
        long created,
        string model,
        string? content,
        JsonArray? toolCalls,
        string? finishReason,
        JsonObject? usage)
    {
        var delta = new JsonObject();
        if (content is not null) delta["content"] = content;
        if (toolCalls is not null) delta["tool_calls"] = toolCalls;
        if (finishReason is null) delta["role"] = "assistant";
        var chunk = new JsonObject
        {
            ["id"] = id,
            ["object"] = "chat.completion.chunk",
            ["created"] = created,
            ["model"] = model,
            ["choices"] = new JsonArray
            {
                new JsonObject
                {
                    ["index"] = 0,
                    ["delta"] = delta,
                    ["finish_reason"] = finishReason,
                },
            },
        };
        if (usage is not null) chunk["usage"] = usage;
        return chunk;
    }

    private static void AppendEvent(StringBuilder output, JsonObject chunk) =>
        output.Append("data: ").Append(chunk.ToJsonString()).Append("\n\n");

    private static JsonObject OpenAiMessage(JsonObject response)
    {
        JsonObject? source = response["message"] as JsonObject;
        var message = new JsonObject
        {
            ["role"] = ReadOptionalString(source?["role"]) ?? "assistant",
            ["content"] = ReadOptionalString(source?["content"]) ?? string.Empty,
        };
        JsonArray? toolCalls = OpenAiToolCalls(source, includeIndex: false);
        if (toolCalls is { Count: > 0 }) message["tool_calls"] = toolCalls;
        return message;
    }

    private static JsonArray? OpenAiToolCalls(JsonObject? message, bool includeIndex)
    {
        JsonArray? source = message?["tool_calls"] as JsonArray
            ?? message?["toolCalls"] as JsonArray;
        if (source is null || source.Count == 0) return null;

        var result = new JsonArray();
        for (int index = 0; index < source.Count; index++)
        {
            if (source[index] is not JsonObject call
                || call["function"] is not JsonObject function)
            {
                continue;
            }
            string? name = ReadOptionalString(function["name"])?.Trim();
            if (string.IsNullOrEmpty(name)) continue;

            string? callId = ReadOptionalString(call["id"])?.Trim();
            string? callType = ReadOptionalString(call["type"])?.Trim();
            var mapped = new JsonObject
            {
                ["id"] = string.IsNullOrEmpty(callId) ? "call_ollama_" + index : callId,
                ["type"] = string.IsNullOrEmpty(callType) ? "function" : callType,
                ["function"] = new JsonObject
                {
                    ["name"] = name,
                    ["arguments"] = OpenAiToolArguments(function["arguments"]),
                },
            };
            if (includeIndex) mapped["index"] = index;
            result.Add(mapped);
        }
        return result.Count == 0 ? null : result;
    }

    private static string OpenAiToolArguments(JsonNode? arguments)
    {
        if (arguments is null) return "{}";
        if (arguments is JsonValue value && value.TryGetValue(out string? text))
        {
            return string.IsNullOrWhiteSpace(text) ? "{}" : text;
        }
        return arguments.ToJsonString();
    }

    private static JsonObject Usage(JsonObject response)
    {
        int prompt = Math.Max(ReadOptionalInt(response["prompt_eval_count"]) ?? 0, 0);
        int completion = Math.Max(ReadOptionalInt(response["eval_count"]) ?? 0, 0);
        return new JsonObject
        {
            ["prompt_tokens"] = prompt,
            ["completion_tokens"] = completion,
            ["total_tokens"] = prompt + completion,
        };
    }

    private static void ValidateResponse(JsonObject response, string model)
    {
        JsonObject? message = response["message"] as JsonObject;
        string content = ReadOptionalString(message?["content"])?.Trim() ?? string.Empty;
        if (content.Length > 0) return;

        string reason = ReadOptionalString(response["done_reason"])?.Trim().ToLowerInvariant()
            ?? string.Empty;
        if (reason is not ("length" or "max_tokens")) return;

        string thinking = ReadOptionalString(message?["thinking"])?.Trim() ?? string.Empty;
        string detail = thinking.Length == 0
            ? $"Upstream returned no assistant text for {model} because it hit the output token limit before producing final content."
            : $"Upstream returned reasoning-only output for {model} and hit the output token limit before final assistant text.";
        throw new ProviderWireFormatException(502, detail);
    }

    private static string FinishReason(string? reason, bool hasToolCalls)
    {
        if (hasToolCalls) return "tool_calls";
        return reason?.ToLowerInvariant() switch
        {
            "length" => "length",
            "tool_calls" => "tool_calls",
            _ => "stop",
        };
    }

    private static void NormalizeMessages(JsonObject source)
    {
        if (source["messages"] is not JsonArray messages) return;
        foreach (JsonNode? item in messages)
        {
            if (item is not JsonObject message) continue;
            NormalizeToolCalls(message, "tool_calls");
            NormalizeToolCalls(message, "toolCalls");
            if (message["content"] is null)
            {
                message["content"] = string.Empty;
            }
            else if (message["content"] is not JsonValue value
                || !value.TryGetValue(out string? _))
            {
                message["content"] = ContentText(message["content"]);
            }
        }
    }

    private static void NormalizeToolCalls(JsonObject message, string key)
    {
        if (message[key] is not JsonArray calls) return;
        foreach (JsonNode? node in calls)
        {
            if (node is not JsonObject call || call["function"] is not JsonObject function) continue;
            if (function["arguments"] is JsonValue value && value.TryGetValue(out string? arguments))
            {
                try
                {
                    function["arguments"] = string.IsNullOrWhiteSpace(arguments)
                        ? new JsonObject()
                        : JsonNode.Parse(arguments) ?? new JsonObject();
                }
                catch (JsonException)
                {
                    function["arguments"] = new JsonObject();
                }
            }
        }
    }

    private static string ContentText(JsonNode? content)
    {
        if (content is JsonValue value && value.TryGetValue(out string? text)) return text ?? string.Empty;
        if (content is not JsonArray blocks) return string.Empty;
        return string.Join("\n", blocks
            .OfType<JsonObject>()
            .Select(block => ReadOptionalString(block["text"]) ?? ReadOptionalString(block["content"]))
            .Where(text => !string.IsNullOrWhiteSpace(text)));
    }

    private static void Move(JsonObject source, JsonObject target, string sourceName, string targetName)
    {
        JsonNode? value = Take(source, sourceName);
        if (value is not null) target[targetName] = value;
    }

    private static JsonNode? Take(JsonObject source, string name)
    {
        JsonNode? value = source[name];
        if (value is not null) source.Remove(name);
        return value;
    }

    private static void ApplyThinkValue(string? effort, JsonObject source)
    {
        switch (effort?.Trim().ToLowerInvariant())
        {
            case "high":
            case "medium":
            case "low":
                source["think"] = effort.Trim().ToLowerInvariant();
                break;
            case "none":
            case "off":
            case "false":
                source["think"] = false;
                break;
        }
    }

    private static JsonObject ParseObject(byte[] body, int status, string error)
    {
        try
        {
            return JsonNode.Parse(body) as JsonObject
                ?? throw new ProviderWireFormatException(status, error);
        }
        catch (JsonException exception)
        {
            throw new ProviderWireFormatException(status, error, exception);
        }
    }

    private static bool ReadBool(JsonNode? node, string error)
    {
        if (node is null) return false;
        if (node is JsonValue value && value.TryGetValue(out bool result)) return result;
        throw new ProviderWireFormatException(400, error);
    }

    private static bool? ReadOptionalBool(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue(out bool result) ? result : null;

    private static int? ReadOptionalInt(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue(out int result) ? result : null;

    private static string? ReadOptionalString(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue(out string? result) ? result : null;
}
