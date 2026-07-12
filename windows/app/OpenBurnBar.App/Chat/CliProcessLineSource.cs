using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Presentation.Chat;

namespace OpenBurnBar.App.Chat;

/// <summary>
/// Production line source: spawn a CLI agent with stream-json output and yield
/// stdout lines for <see cref="CliJsonLineChatStreamDriver"/>. Uses
/// <see cref="Process"/> (portable; works on macOS authoring host and Windows).
/// ConPTY is available separately for interactive terminal surfaces.
/// </summary>
public static class CliProcessLineSource
{
    /// <summary>Default Claude Code print + stream-json command, displayed only for diagnostics.</summary>
    public const string DefaultCommandTemplate =
        "claude -p <structured-prompt> --output-format stream-json --verbose";

    public static string ResolveCommandLine(string userText, string? commandTemplateForTests = null)
    {
        ChildProcessSpec spec = ResolveProcessSpec(userText, commandTemplateForTests);
        return spec.DisplayCommandLine;
    }

    public static ChildProcessSpec ResolveProcessSpec(string userText, string? commandTemplateForTests = null)
    {
        if (!string.IsNullOrWhiteSpace(commandTemplateForTests))
        {
            if (commandTemplateForTests.Contains("{0}", StringComparison.Ordinal))
            {
                return ChildProcessSpec.Parse(string.Format(null, commandTemplateForTests, QuoteForCommandLine(userText)));
            }

            ChildProcessSpec parsed = ChildProcessSpec.Parse(commandTemplateForTests.Trim());
            return parsed.WithAdditionalArguments("-p", userText);
        }

        return new ChildProcessSpec(
            "claude",
            new[] { "-p", userText, "--output-format", "stream-json", "--verbose" });
    }

    /// <summary>Compatibility overload for tests that still pass a display command.</summary>
    public static async IAsyncEnumerable<string> ReadLinesAsync(
        string commandLine,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        await foreach (string line in ReadLinesAsync(ChildProcessSpec.Parse(commandLine), cancellationToken)
            .ConfigureAwait(false))
        {
            yield return line;
        }
    }

    public static async IAsyncEnumerable<string> ReadLinesAsync(
        ChildProcessSpec spec,
        ApprovedChatExecutableCatalog? catalog,
        ChatProcessLimits? limits,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        await foreach (ChatProcessLine output in ChatProcessRunner
            .StreamStdoutLinesAsync(spec, catalog, limits, cancellationToken)
            .ConfigureAwait(false))
        {
            if (output.IsFailure)
            {
                yield return ErrorLine(
                    output.FailureKind ?? ChatFailureKind.StreamError,
                    output.FailureMessage ?? "The chat process failed.");
                yield break;
            }

            if (!string.IsNullOrEmpty(output.Line))
            {
                yield return output.Line;
            }
        }
    }

    public static IAsyncEnumerable<string> ReadLinesAsync(
        ChildProcessSpec spec,
        CancellationToken cancellationToken)
    {
        return ReadLinesAsync(spec, null, null, cancellationToken);
    }

    /// <summary>Factory adapter for <see cref="CliJsonLineChatStreamDriver"/>.</summary>
    public static IAsyncEnumerable<string> ForChatTurn(
        string userText,
        IReadOnlyList<ChatMessageRecord> history,
        CancellationToken cancellationToken)
    {
        _ = history;
        return ReadLinesAsync(ResolveProcessSpec(userText), cancellationToken);
    }

    internal static ProcessStartInfo CreateStartInfo(ChildProcessSpec spec)
    {
        return ChatProcessRunner.CreateStartInfo(
            spec,
            ProtectedChatExecutableInventoryStore.CreateDefault().LoadCatalog());
    }

    private static string ErrorLine(ChatFailureKind kind, string message)
    {
        message = SecretRedactor.Shared.Redact(message);
        return JsonSerializer.Serialize(new
        {
            openburnbar_stream_error = new
            {
                kind = kind.ToString(),
                message,
            },
        });
    }

    private static string QuoteForCommandLine(string value) =>
        "\"" + value.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("\"", "\\\"", StringComparison.Ordinal) + "\"";
}

public sealed record ChildProcessSpec(
    string FileName,
    IReadOnlyList<string> Arguments,
    string? StandardInput = null)
{
    public string DisplayCommandLine =>
        FileName + (Arguments.Count == 0 ? string.Empty : " " + string.Join(" ", Arguments.Select(QuoteIfNeeded)));

    public static ChildProcessSpec Parse(string commandLine)
    {
        IReadOnlyList<string> parts = SplitCommandLine(commandLine);
        if (parts.Count == 0)
        {
            throw new ArgumentException("Command line must name an executable.", nameof(commandLine));
        }

        return new ChildProcessSpec(parts[0], parts.Skip(1).ToArray());
    }

    public ChildProcessSpec WithAdditionalArguments(params string[] arguments) =>
        new(FileName, Arguments.Concat(arguments).ToArray(), StandardInput);

    private static IReadOnlyList<string> SplitCommandLine(string commandLine)
    {
        var parts = new List<string>();
        var current = new StringBuilder();
        bool inQuote = false;
        for (int i = 0; i < commandLine.Length; i++)
        {
            char ch = commandLine[i];
            if (ch == '\\' && i + 1 < commandLine.Length && commandLine[i + 1] == '"')
            {
                current.Append('"');
                i++;
                continue;
            }

            if (ch == '"')
            {
                inQuote = !inQuote;
                continue;
            }

            if (char.IsWhiteSpace(ch) && !inQuote)
            {
                if (current.Length > 0)
                {
                    parts.Add(current.ToString());
                    current.Clear();
                }

                continue;
            }

            current.Append(ch);
        }

        if (current.Length > 0)
        {
            parts.Add(current.ToString());
        }

        return parts;
    }

    private static string QuoteIfNeeded(string value)
    {
        if (value.Length == 0 || value.Any(char.IsWhiteSpace) || value.Contains('"', StringComparison.Ordinal))
        {
            return "\"" + value.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("\"", "\\\"", StringComparison.Ordinal) + "\"";
        }

        return value;
    }
}
