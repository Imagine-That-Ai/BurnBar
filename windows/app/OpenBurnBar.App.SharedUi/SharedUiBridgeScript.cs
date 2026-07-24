using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace OpenBurnBar.App.SharedUi;

/// <summary>
/// Builds the <c>window.__obbShimDispatch("...")</c> script the host executes to
/// deliver a message to the renderer. The JS string-literal escaping is kept
/// character-for-character identical to <c>OpenBurnBar.Pretext.PretextBridge</c>
/// (and through it, the Swift PretextEngine bridge): backslash first, then
/// double-quote, \n, \r, \t, U+2028, U+2029. A dedicated parity test pins the
/// exact output so the two bridges can never drift apart.
/// </summary>
public static class SharedUiBridgeScript
{
    private static readonly JsonSerializerOptions CompactJson = new()
    {
        WriteIndented = false,
    };

    /// <summary>
    /// Escape a JSON payload for safe embedding inside a double-quoted JS string
    /// literal. Order matters: backslash MUST be escaped first so later-inserted
    /// escapes are not doubled.
    /// </summary>
    public static string EscapeForJsStringLiteral(string json)
    {
        var sb = new StringBuilder(json.Length + 16);
        foreach (var c in json)
        {
            switch (c)
            {
                case '\\':
                    sb.Append("\\\\");
                    break;
                case '"':
                    sb.Append("\\\"");
                    break;
                case '\n':
                    sb.Append("\\n");
                    break;
                case '\r':
                    sb.Append("\\r");
                    break;
                case '\t':
                    sb.Append("\\t");
                    break;
                case '\u2028':
                    sb.Append("\\u2028");
                    break;
                case '\u2029':
                    sb.Append("\\u2029");
                    break;
                default:
                    sb.Append(c);
                    break;
            }
        }

        return sb.ToString();
    }

    /// <summary>
    /// Build the full dispatch script for an outbound message:
    /// <c>window.__obbShimDispatch &amp;&amp; window.__obbShimDispatch("...");</c>
    /// The guard mirrors the Pretext host so a not-yet-loaded page never throws.
    /// </summary>
    public static string BuildDispatchScript(JsonObject message)
    {
        var json = message.ToJsonString(CompactJson);
        var escaped = EscapeForJsStringLiteral(json);
        return "window." + SharedUiBridgeMessage.DispatchGlobal + " && window." +
               SharedUiBridgeMessage.DispatchGlobal + "(\"" + escaped + "\");";
    }
}
