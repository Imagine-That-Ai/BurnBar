using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace OpenBurnBar.App.ManagedAgentRuntime.Gateway;

public static partial class AnthropicProviderAdapter
{
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
