using System;
using System.Collections.Generic;
using System.Threading;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Presentation.Chat;

namespace OpenBurnBar.App.Chat;

/// <summary>
/// Production composition root for chat backends (H3).
/// Sample mode → scripted demo; otherwise live CLI process stream-json →
/// <see cref="CliJsonLineChatStreamDriver"/> (real production path).
/// Opt out with <c>OPENBURNBAR_CLI_DISABLE=1</c> for explicit unavailable guidance.
/// </summary>
public static class ChatStreamDriverFactory
{
    /// <summary>Set to 1/true to force unavailable (honest disable) instead of process spawn.</summary>
    public const string CliDisableEnv = "OPENBURNBAR_CLI_DISABLE";

    /// <summary>True when CLI chat is not explicitly disabled.</summary>
    public static bool IsCliConfigured() => !IsCliDisabled();

    public static bool IsCliDisabled()
    {
        string? flag = Environment.GetEnvironmentVariable(CliDisableEnv);
        return string.Equals(flag, "1", StringComparison.Ordinal)
            || string.Equals(flag, "true", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Resolve the production default driver. Optional <paramref name="configuredLineSource"/>
    /// injects canned NDJSON for tests; production uses <see cref="CliProcessLineSource.ForChatTurn"/>.
    /// </summary>
    public static IChatStreamDriver CreateDefault(
        Func<string, IReadOnlyList<ChatMessageRecord>, CancellationToken, IAsyncEnumerable<string>>? configuredLineSource = null)
    {
        if (RuntimeDataMode.SampleModeEnabled)
        {
            return new ScriptedChatStreamDriver();
        }

        if (IsCliDisabled())
        {
            return new UnavailableChatStreamDriver();
        }

        // Production default: live process stream-json through the shipped parser.
        Func<string, IReadOnlyList<ChatMessageRecord>, CancellationToken, IAsyncEnumerable<string>> lines =
            configuredLineSource ?? CliProcessLineSource.ForChatTurn;
        return new CliJsonLineChatStreamDriver(lines);
    }
}
