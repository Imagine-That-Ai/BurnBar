using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;

namespace OpenBurnBar.Cli;

public sealed class CompanionCliApplication
{
    public const int MaxInputBytes = CompanionCliServer.MaxLineBytes - 1024;

    private static readonly IReadOnlyDictionary<string, string> OperationAliases =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["ping"] = "ping",
            ["version"] = "version",
            ["health"] = "health",
            ["models"] = "models",
            ["run-submit"] = "run.submit",
            ["run-resume"] = "run.resume",
            ["run-recover"] = "run.recover",
            ["run-get"] = "run.get",
            ["run-poll"] = "run.poll",
            ["run-cancel"] = "run.cancel",
            ["run-retry"] = "run.retry",
            ["approval-respond"] = "approval.respond",
            ["tool-claim"] = "workspace.executeTool",
            ["tool-result"] = "workspace.toolResult",
            ["mission-submit"] = "mission.submit",
            ["mission-resume"] = "mission.resume",
            ["plan"] = "planner.plan",
            ["policy"] = "policy.evaluate",
            ["fusion"] = "fusion.run",
            ["code-index"] = "code.index",
            ["code-search"] = "code.search",
            ["code-symbol"] = "code.symbol",
            ["code-status"] = "code.status",
            ["code-context"] = "code.context_pack",
            ["code-references"] = "code.references",
            ["code-call-graph"] = "code.call_graph",
            ["code-semantic-search"] = "code.semantic_search",
        };

    private readonly Func<CompanionCliClientOptions, ICompanionCliClient> _clientFactory;

    public CompanionCliApplication(Func<CompanionCliClientOptions, ICompanionCliClient> clientFactory)
    {
        _clientFactory = clientFactory ?? throw new ArgumentNullException(nameof(clientFactory));
    }

    public async Task<int> RunAsync(
        IReadOnlyList<string> args,
        TextReader input,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(args);
        ArgumentNullException.ThrowIfNull(input);
        ArgumentNullException.ThrowIfNull(output);
        ArgumentNullException.ThrowIfNull(error);

        try
        {
            ParsedInvocation invocation = Parse(args);
            if (invocation.ShowHelp)
            {
                await output.WriteLineAsync(Usage).ConfigureAwait(false);
                return 0;
            }

            JsonObject request = await LoadRequestAsync(invocation, input, cancellationToken).ConfigureAwait(false);
            request["op"] = invocation.Operation;
            using JsonDocument requestDocument = JsonDocument.Parse(request.ToJsonString());
            var options = new CompanionCliClientOptions(
                invocation.Port,
                TimeSpan.FromSeconds(invocation.TimeoutSeconds),
                invocation.RequireAuthentication);
            JsonElement response = await _clientFactory(options)
                .ExchangeAsync(requestDocument.RootElement, cancellationToken)
                .ConfigureAwait(false);

            var serializerOptions = new JsonSerializerOptions { WriteIndented = !invocation.Compact };
            await output.WriteLineAsync(JsonSerializer.Serialize(response, serializerOptions)).ConfigureAwait(false);
            return ResponseSucceeded(response) ? 0 : 2;
        }
        catch (OperationCanceledException)
        {
            await error.WriteLineAsync("cancelled: The companion request was cancelled.").ConfigureAwait(false);
            return 130;
        }
        catch (CompanionCliClientException exception)
        {
            await error.WriteLineAsync(exception.Code + ": " + exception.Message).ConfigureAwait(false);
            return 1;
        }
        catch (CompanionCliUsageException exception)
        {
            await error.WriteLineAsync("usage: " + exception.Message).ConfigureAwait(false);
            await error.WriteLineAsync("Run `OpenBurnBar.Cli.exe --help` for command details.").ConfigureAwait(false);
            return 64;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            await error.WriteLineAsync("input_error: " + exception.Message).ConfigureAwait(false);
            return 1;
        }
    }

    private static ParsedInvocation Parse(IReadOnlyList<string> args)
    {
        if (args.Count == 0)
        {
            throw new CompanionCliUsageException("A command is required.");
        }

        string command = args[0];
        if (command is "--help" or "-h" or "help")
        {
            return ParsedInvocation.Help;
        }

        string operation;
        var index = 1;
        if (string.Equals(command, "call", StringComparison.OrdinalIgnoreCase))
        {
            if (args.Count < 2 || args[1].StartsWith("-", StringComparison.Ordinal))
            {
                throw new CompanionCliUsageException("`call` requires a protocol operation name.");
            }

            operation = args[1];
            index = 2;
        }
        else if (!OperationAliases.TryGetValue(command, out operation!))
        {
            throw new CompanionCliUsageException("Unknown command `" + command + "`.");
        }

        string? inputPath = null;
        var port = 8765;
        var timeoutSeconds = 15;
        var compact = false;
        var requireAuthentication = true;
        while (index < args.Count)
        {
            string option = args[index++];
            switch (option)
            {
                case "--input":
                    inputPath = RequireValue(args, ref index, option);
                    break;
                case "--port":
                    port = ParseInteger(RequireValue(args, ref index, option), option, 1, 65535);
                    break;
                case "--timeout-seconds":
                    timeoutSeconds = ParseInteger(RequireValue(args, ref index, option), option, 1, 300);
                    break;
                case "--compact":
                    compact = true;
                    break;
                case "--no-auth":
                    requireAuthentication = false;
                    break;
                default:
                    throw new CompanionCliUsageException("Unknown option `" + option + "`.");
            }
        }

        return new ParsedInvocation(
            operation,
            inputPath,
            port,
            timeoutSeconds,
            compact,
            requireAuthentication,
            ShowHelp: false);
    }

    private static async Task<JsonObject> LoadRequestAsync(
        ParsedInvocation invocation,
        TextReader input,
        CancellationToken cancellationToken)
    {
        if (invocation.InputPath is null)
        {
            return new JsonObject();
        }

        string json;
        if (invocation.InputPath == "-")
        {
            json = await ReadBoundedAsync(input, cancellationToken).ConfigureAwait(false);
        }
        else
        {
            var file = new FileInfo(Path.GetFullPath(invocation.InputPath));
            if (!file.Exists)
            {
                throw new CompanionCliUsageException("Input file does not exist: " + file.FullName);
            }

            if (file.Length > MaxInputBytes)
            {
                throw new CompanionCliUsageException("Input file exceeds the companion request limit.");
            }

            json = await File.ReadAllTextAsync(file.FullName, cancellationToken).ConfigureAwait(false);
        }

        JsonNode? parsed = JsonNode.Parse(json);
        if (parsed is not JsonObject root)
        {
            throw new CompanionCliUsageException("Input must be a JSON object.");
        }
        if (root.ContainsKey("authToken"))
        {
            throw new CompanionCliUsageException("Input JSON must not contain `authToken`; authentication comes from protected storage.");
        }

        return root;
    }

    private static async Task<string> ReadBoundedAsync(TextReader reader, CancellationToken cancellationToken)
    {
        char[] buffer = new char[4096];
        using var writer = new StringWriter(CultureInfo.InvariantCulture);
        var totalBytes = 0;
        while (true)
        {
            int count = await reader.ReadAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false);
            if (count == 0) break;
            totalBytes += System.Text.Encoding.UTF8.GetByteCount(buffer.AsSpan(0, count));
            if (totalBytes > MaxInputBytes)
            {
                throw new CompanionCliUsageException("Standard input exceeds the companion request limit.");
            }
            writer.Write(buffer, 0, count);
        }
        return writer.ToString();
    }

    private static bool ResponseSucceeded(JsonElement response) =>
        response.TryGetProperty("ok", out JsonElement ok)
        && ok.ValueKind is JsonValueKind.True;

    private static string RequireValue(IReadOnlyList<string> args, ref int index, string option)
    {
        if (index >= args.Count)
        {
            throw new CompanionCliUsageException(option + " requires a value.");
        }
        return args[index++];
    }

    private static int ParseInteger(string value, string option, int minimum, int maximum)
    {
        if (!int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out int parsed)
            || parsed < minimum
            || parsed > maximum)
        {
            throw new CompanionCliUsageException($"{option} must be between {minimum} and {maximum}.");
        }
        return parsed;
    }

    private sealed record ParsedInvocation(
        string Operation,
        string? InputPath,
        int Port,
        int TimeoutSeconds,
        bool Compact,
        bool RequireAuthentication,
        bool ShowHelp)
    {
        public static readonly ParsedInvocation Help = new(
            string.Empty, null, 8765, 15, false, true, ShowHelp: true);
    }

    private sealed class CompanionCliUsageException : Exception
    {
        public CompanionCliUsageException(string message) : base(message) { }
    }

    private const string Usage = """
OpenBurnBar companion CLI

Usage:
  OpenBurnBar.Cli.exe <command> [--input <file|->] [--port <1-65535>]
                       [--timeout-seconds <1-300>] [--compact] [--no-auth]
  OpenBurnBar.Cli.exe call <protocol-op> [options]

Read-only commands:
  ping  version  health  models

Run commands:
  run-submit  run-resume  run-recover  run-get  run-poll  run-cancel  run-retry
  approval-respond  tool-claim  tool-result

Workflow commands:
  mission-submit  mission-resume  plan  policy  fusion
  code-index  code-search  code-symbol  code-status  code-context
  code-references  code-call-graph  code-semantic-search

Request bodies are JSON objects read from --input. Use --input - for stdin.
Authentication is read from the current user's DPAPI-protected OpenBurnBar store.
--no-auth works only when the desktop app explicitly allows unauthenticated loopback.
""";
}
