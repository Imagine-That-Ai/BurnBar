using System.Text;
using System.Text.Json.Nodes;

namespace OpenBurnBar.App.SharedUi;

/// <summary>
/// The gateway_chat_stream request validator — a mirror of
/// validate_gateway_request in apps/linux-desktop/src-tauri/src/lib.rs, with
/// the exact error-string taxonomy the frontend's nativeGatewayError mapper
/// and the Rust unit tests pin.
/// </summary>
public static class SharedUiGatewayChatValidator
{
    public const int MaxMessages = 256;
    public const int MaxContentBytes = 1_048_576; // 1 MiB
    public const int MaxResponseBytes = 16_777_216; // 16 MiB
    public const int MaxModelLength = 256;
    public const int MaxRequestIdLength = 128;

    /// <summary>
    /// Validate the { request: { requestId, model, messages[] } } args payload.
    /// Returns the request fields on success; throws SharedUiCommandException
    /// with the gateway_invalid_* wire error otherwise.
    /// </summary>
    public static (string RequestId, string Model, JsonArray Messages) ValidateRequest(JsonObject args)
    {
        var request = args["request"] as JsonObject
                      ?? throw new SharedUiCommandException("gateway_invalid_request");

        var requestId = request["requestId"] is JsonValue idValue && idValue.TryGetValue(out string? rid)
            ? rid ?? string.Empty
            : string.Empty;
        if (!IsValidRequestId(requestId))
        {
            throw new SharedUiCommandException("gateway_invalid_request_id");
        }

        var model = request["model"] is JsonValue modelValue && modelValue.TryGetValue(out string? m)
            ? (m ?? string.Empty).Trim()
            : string.Empty;
        if (model.Length == 0 || model.Length > MaxModelLength)
        {
            throw new SharedUiCommandException("gateway_invalid_model");
        }

        if (request["messages"] is not JsonArray messages || messages.Count == 0 || messages.Count > MaxMessages)
        {
            throw new SharedUiCommandException("gateway_invalid_message_count");
        }

        long contentBytes = 0;
        foreach (var node in messages)
        {
            var role = node is JsonObject message
                       && message["role"] is JsonValue roleValue
                       && roleValue.TryGetValue(out string? r)
                ? r
                : null;
            if (role is not ("system" or "user" or "assistant" or "tool"))
            {
                throw new SharedUiCommandException("gateway_invalid_message_role");
            }

            var content = node is JsonObject messageObj
                          && messageObj["content"] is JsonValue contentValue
                          && contentValue.TryGetValue(out string? c)
                ? c ?? string.Empty
                : string.Empty;
            // Rust measures content.len() in BYTES — mirror with UTF-8 byte count.
            contentBytes += Encoding.UTF8.GetByteCount(content);
            if (contentBytes > MaxContentBytes)
            {
                throw new SharedUiCommandException("gateway_request_too_large");
            }
        }

        return (requestId, model, messages);
    }

    /// <summary>[A-Za-z0-9-_]{1,128} — ASCII only, matching the Rust byte loop.</summary>
    public static bool IsValidRequestId(string requestId)
    {
        if (requestId.Length == 0 || requestId.Length > MaxRequestIdLength)
        {
            return false;
        }

        foreach (var c in requestId)
        {
            var ok = c is (>= 'a' and <= 'z') or (>= 'A' and <= 'Z') or (>= '0' and <= '9') or '-' or '_';
            if (!ok)
            {
                return false;
            }
        }

        return true;
    }
}
