using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Presentation.Chat;

namespace OpenBurnBar.App.Chat;

/// <summary>
/// Production composition root for chat backends (H3). Sample mode → scripted demo;
/// configured CLI command → <see cref="CliJsonLineChatStreamDriver"/>; else honest unavailable.
/// </summary>
public static class ChatStreamDriverFactory
{
    /// <summary>Env var for the CLI command line (same family as <c>OPENBURNBAR_CLI_COMMAND</c>).</summary>
    public const string CliCommandEnv = "OPENBURNBAR_CLI_COMMAND";

    /// <summary>True when a production CLI command is configured for stream-json chat.</summary>
    public static bool IsCliConfigured()
    {
        string? command = Environment.GetEnvironmentVariable(CliCommandEnv);
        return !string.IsNullOrWhiteSpace(command);
    }

    /// <summary>
    /// Resolve the production default driver. Optional <paramref name="configuredLineSource"/>
    /// is used when CLI is configured (tests inject canned NDJSON; Windows host injects process reader).
    /// </summary>
    public static IChatStreamDriver CreateDefault(
        Func<string, IReadOnlyList<ChatMessageRecord>, CancellationToken, IAsyncEnumerable<string>>? configuredLineSource = null)
    {
        if (RuntimeDataMode.SampleModeEnabled)
        {
            return new ScriptedChatStreamDriver();
        }

        if (IsCliConfigured())
        {
            Func<string, IReadOnlyList<ChatMessageRecord>, CancellationToken, IAsyncEnumerable<string>> lines =
                configuredLineSource ?? DefaultConfiguredLineSource;
            return new CliJsonLineChatStreamDriver(lines);
        }

        return new UnavailableChatStreamDriver();
    }

    /// <summary>
    /// Placeholder line source when CLI is configured but no process adapter is injected.
    /// Yields a single explicit system line so the surface never freezes silently.
    /// Host adapters replace this with real process stdout NDJSON.
    /// </summary>
    private static async IAsyncEnumerable<string> DefaultConfiguredLineSource(
        string userText,
        IReadOnlyList<ChatMessageRecord> history,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        await Task.Yield();
        cancellationToken.ThrowIfCancellationRequested();
        // Emit a valid stream-json text line so the production driver path is exercised
        // even before ConPTY process plumbing is attached.
        string escaped = userText.Replace("\\", "\\\\", StringComparison.Ordinal)
            .Replace("\"", "\\\"", StringComparison.Ordinal);
        yield return "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"CLI backend configured (OPENBURNBAR_CLI_COMMAND). Host process adapter will stream live tokens for: "
            + escaped
            + "\"}]}}";
    }
}
