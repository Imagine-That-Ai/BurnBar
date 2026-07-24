using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.ManagedAgentRuntime.Gateway;

public sealed record ProviderCliProcessRequest(
    string ExecutableId,
    IReadOnlyList<string> Arguments,
    IReadOnlyDictionary<string, string> RequiredEnvironment,
    string WorkingDirectory,
    string? StandardInput,
    TimeSpan Timeout);

public sealed record ProviderCliProcessResult(int ExitCode, string Stdout, string Stderr);

/// <summary>Protected, bounded child-process boundary supplied by the Windows host.</summary>
public interface IProviderCliProcessRunner
{
    Task<ProviderCliProcessResult> RunAsync(
        ProviderCliProcessRequest request,
        CancellationToken cancellationToken = default);
}

/// <summary>Dispatches CLI-backed routes without changing HTTP provider behavior.</summary>
public sealed class CompositeModelCompletionExecutor : IModelCompletionExecutor
{
    private readonly IModelCompletionExecutor _http;
    private readonly IModelCompletionExecutor _cli;

    public CompositeModelCompletionExecutor(
        IModelCompletionExecutor http,
        IModelCompletionExecutor cli)
    {
        _http = http ?? throw new ArgumentNullException(nameof(http));
        _cli = cli ?? throw new ArgumentNullException(nameof(cli));
    }

    public Task<ModelCompletionResult> ExecuteAsync(
        ModelRoute route,
        byte[] requestBody,
        CancellationToken cancellationToken = default) =>
        ProviderCliModelCompletionExecutor.IsCliRoute(route)
            ? _cli.ExecuteAsync(route, requestBody, cancellationToken)
            : _http.ExecuteAsync(route, requestBody, cancellationToken);
}

/// <summary>Codex and Factory Droid provider executors matching the macOS guarded CLI contracts.</summary>
public sealed class ProviderCliModelCompletionExecutor : IModelCompletionExecutor
{
    public const int MaximumPromptCharacters = 1024 * 1024;
    private static readonly TimeSpan DefaultTimeout = TimeSpan.FromMinutes(2);
    private static readonly HashSet<string> DroidCoreModelIds = new(StringComparer.OrdinalIgnoreCase)
    {
        "glm-5.1", "kimi-k2.6", "kimi-k2.5", "deepseek-v4-pro", "minimax-m2.7", "minimax-m2.5",
    };

    private readonly IProviderCliProcessRunner _runner;
    private readonly TimeSpan _timeout;

    public ProviderCliModelCompletionExecutor(
        IProviderCliProcessRunner runner,
        TimeSpan? timeout = null)
    {
        _runner = runner ?? throw new ArgumentNullException(nameof(runner));
        _timeout = timeout ?? DefaultTimeout;
        if (_timeout <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(timeout));
    }

    public static bool IsCliProvider(string vendor) =>
        string.Equals(vendor, "factory", StringComparison.OrdinalIgnoreCase)
        || string.Equals(vendor, "factory-droid", StringComparison.OrdinalIgnoreCase);

    public static bool IsCliRoute(ModelRoute route) =>
        route.Endpoint is not null
        && GatewayRouteConfiguration.IsCliEndpointAllowed(route.Endpoint, route.Vendor);

    public async Task<ModelCompletionResult> ExecuteAsync(
        ModelRoute route,
        byte[] requestBody,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(route);
        ArgumentNullException.ThrowIfNull(requestBody);
        if (!route.IsExecutable || !IsCliRoute(route))
        {
            return Failure(503, "cli_route_unavailable");
        }

        (string prompt, bool stream) parsed;
        try
        {
            parsed = Prompt(requestBody, route.Vendor);
        }
        catch (ProviderWireFormatException error)
        {
            return Failure(error.StatusCode, error.Message);
        }

        string directory = Path.Combine(
            Path.GetTempPath(),
            "openburnbar-provider-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            ProviderCliProcessRequest processRequest;
            try
            {
                processRequest = IsCodex(route.Vendor)
                    ? CodexRequest(route, parsed.prompt, directory)
                    : FactoryRequest(route, parsed.prompt, directory);
            }
            catch (ProviderWireFormatException error)
            {
                return Failure(error.StatusCode, error.Message);
            }
            ProviderCliProcessResult result;
            try
            {
                result = await _runner.RunAsync(processRequest, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (TimeoutException)
            {
                return Failure(504, "provider_cli_timeout");
            }
            catch
            {
                return Failure(502, "provider_cli_launch_failed");
            }

            string combined = result.Stdout + "\n" + result.Stderr;
            if (result.ExitCode != 0)
            {
                return Failure(ClassifyStatus(combined), "provider_cli_failed");
            }
            if (!IsCodex(route.Vendor)
                && !DroidCoreModelIds.Contains(route.Model.Trim())
                && ContainsDroidCoreDowngrade(combined))
            {
                return Failure(402, "factory_standard_usage_exhausted");
            }

            string output = IsCodex(route.Vendor)
                ? ExtractCodexMessage(result.Stdout)
                : ExtractFactoryMessage(result.Stdout);
            if (string.IsNullOrWhiteSpace(output))
            {
                return Failure(502, "provider_cli_empty_response");
            }
            return Success(route.Model, parsed.prompt, output.Trim(), parsed.stream);
        }
        finally
        {
            try { Directory.Delete(directory, recursive: true); } catch { /* best effort */ }
        }
    }

    private ProviderCliProcessRequest CodexRequest(ModelRoute route, string prompt, string directory)
    {
        var arguments = new List<string>
        {
            "exec", "--json", "--ephemeral", "--skip-git-repo-check",
            "-c", "model_reasoning_effort=\"high\"",
        };
        if (!string.IsNullOrWhiteSpace(route.Model))
        {
            arguments.AddRange(new[] { "-m", route.Model.Trim() });
        }
        arguments.AddRange(new[]
        {
            "--sandbox", "read-only", "--ignore-user-config", "--ignore-rules", "-",
        });
        var environment = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (!string.IsNullOrWhiteSpace(route.BearerToken))
        {
            environment["OPENAI_API_KEY"] = route.BearerToken.Trim();
        }
        return new ProviderCliProcessRequest(
            "codex",
            arguments,
            environment,
            directory,
            prompt,
            _timeout);
    }

    private ProviderCliProcessRequest FactoryRequest(ModelRoute route, string prompt, string directory)
    {
        if (string.IsNullOrWhiteSpace(route.BearerToken))
        {
            throw new ProviderWireFormatException(401, "factory_api_key_missing");
        }
        string promptPath = Path.Combine(directory, "prompt.txt");
        File.WriteAllText(promptPath, prompt, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        var environment = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["FACTORY_API_KEY"] = route.BearerToken.Trim(),
            ["OPENBURNBAR_FACTORY_STRICT_STANDARD"] = "1",
        };
        return new ProviderCliProcessRequest(
            "droid",
            new[]
            {
                "exec", "--model", route.Model, "--output-format", "json",
                "--cwd", directory, "--disabled-tools", "ApplyPatch,execute-cli",
                "-f", promptPath,
            },
            environment,
            directory,
            StandardInput: null,
            _timeout);
    }

    private static (string Prompt, bool Stream) Prompt(byte[] body, string vendor)
    {
        JsonObject root;
        try
        {
            root = JsonNode.Parse(body) as JsonObject
                ?? throw new ProviderWireFormatException(400, "provider_cli_request_invalid");
        }
        catch (JsonException error)
        {
            throw new ProviderWireFormatException(400, "provider_cli_request_invalid", error);
        }

        bool stream = false;
        if (root["stream"] is JsonNode streamNode)
        {
            if (streamNode is not JsonValue streamValue || !streamValue.TryGetValue(out stream))
            {
                throw new ProviderWireFormatException(400, "provider_cli_stream_invalid");
            }
        }
        string providerName = IsCodex(vendor) ? "Codex" : "Factory Droid";
        var parts = new List<string>
        {
            $"You are serving one OpenBurnBar routed completion request through {providerName}.\n"
            + "Return only the assistant response for the user request.\n"
            + "Do not inspect or modify files, run commands, call tools, change models, or mention routing internals.",
        };
        if (root["messages"] is JsonArray messages)
        {
            foreach (JsonNode? node in messages)
            {
                if (node is not JsonObject message) continue;
                string role = ReadString(message["role"])?.Trim() ?? string.Empty;
                if (role.Length == 0) role = "user";
                string content = Text(message["content"]);
                if (content.Length > 0)
                {
                    parts.Add(char.ToUpperInvariant(role[0]) + role[1..].ToLowerInvariant() + ":\n" + content);
                }
            }
        }
        if (root["response_format"] is JsonObject format
            && string.Equals(ReadString(format["type"]), "json_object", StringComparison.Ordinal))
        {
            parts.Add("Return valid JSON only.");
        }
        string prompt = string.Join("\n\n", parts);
        if (prompt.Length > MaximumPromptCharacters)
        {
            throw new ProviderWireFormatException(413, "provider_cli_prompt_too_large");
        }
        return (prompt, stream);
    }

    private static string Text(JsonNode? value)
    {
        if (value is JsonValue scalar && scalar.TryGetValue(out string? text)) return text ?? string.Empty;
        if (value is JsonArray array)
        {
            return string.Join("\n", array.Select(Text).Where(item => item.Length > 0));
        }
        if (value is not JsonObject obj) return string.Empty;
        string? direct = ReadString(obj["text"]);
        if (!string.IsNullOrEmpty(direct)) return direct;
        string nested = Text(obj["content"]);
        return nested.Length > 0
            ? nested
            : ReadString(obj["output_text"]) ?? string.Empty;
    }

    private static string ExtractCodexMessage(string jsonl)
    {
        string latest = string.Empty;
        foreach (string line in jsonl.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                if (JsonNode.Parse(line) is not JsonObject obj) continue;
                string? text = null;
                if (obj["item"] is JsonObject item
                    && string.Equals(ReadString(item["type"]), "agent_message", StringComparison.Ordinal))
                {
                    text = ReadString(item["text"]);
                }
                text ??= obj["message"] is JsonObject message ? ReadString(message["text"]) : null;
                if (!string.IsNullOrWhiteSpace(text)) latest = text;
            }
            catch (JsonException)
            {
                // Non-JSON progress lines carry no trusted assistant response.
            }
        }
        return latest;
    }

    private static string ExtractFactoryMessage(string stdout)
    {
        string trimmed = stdout.Trim();
        try
        {
            return JsonNode.Parse(trimmed) is JsonNode node
                ? TextCandidate(node) ?? trimmed
                : trimmed;
        }
        catch (JsonException)
        {
            return trimmed;
        }
    }

    private static string? TextCandidate(JsonNode node)
    {
        if (node is JsonValue value && value.TryGetValue(out string? text)) return text;
        if (node is JsonArray array)
        {
            string joined = string.Join("\n", array
                .Where(item => item is not null)
                .Select(item => TextCandidate(item!))
                .Where(item => !string.IsNullOrEmpty(item)));
            return joined.Length == 0 ? null : joined;
        }
        if (node is not JsonObject obj) return null;
        foreach (string key in new[] { "result", "response", "content", "message", "text", "output", "summary" })
        {
            if (obj[key] is JsonNode child && TextCandidate(child) is string candidate && candidate.Length > 0)
            {
                return candidate;
            }
        }
        if (obj["choices"] is JsonArray choices
            && choices.FirstOrDefault() is JsonObject choice
            && choice["message"] is JsonNode choiceMessage)
        {
            return TextCandidate(choiceMessage);
        }
        return null;
    }

    private static ModelCompletionResult Success(string model, string prompt, string output, bool stream)
    {
        int inputTokens = Math.Max(1, prompt.Length / 4);
        int outputTokens = Math.Max(1, output.Length / 4);
        JsonObject usage = new()
        {
            ["prompt_tokens"] = inputTokens,
            ["completion_tokens"] = outputTokens,
            ["total_tokens"] = inputTokens + outputTokens,
        };
        string id = "chatcmpl-openburnbar-cli-" + Guid.NewGuid().ToString("N");
        long created = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        if (!stream)
        {
            var body = new JsonObject
            {
                ["id"] = id,
                ["object"] = "chat.completion",
                ["created"] = created,
                ["model"] = model,
                ["choices"] = new JsonArray
                {
                    new JsonObject
                    {
                        ["index"] = 0,
                        ["message"] = new JsonObject { ["role"] = "assistant", ["content"] = output },
                        ["finish_reason"] = "stop",
                    },
                },
                ["usage"] = usage,
            };
            return new ModelCompletionResult(200, JsonSerializer.SerializeToUtf8Bytes(body), "application/json", true);
        }

        JsonObject first = StreamChunk(id, created, model, output, null, null);
        JsonObject final = StreamChunk(id, created, model, null, "stop", usage);
        string sse = "data: " + first.ToJsonString() + "\n\n"
            + "data: " + final.ToJsonString() + "\n\n"
            + "data: [DONE]\n\n";
        return new ModelCompletionResult(200, Encoding.UTF8.GetBytes(sse), "text/event-stream", true);
    }

    private static JsonObject StreamChunk(
        string id,
        long created,
        string model,
        string? content,
        string? finishReason,
        JsonObject? usage)
    {
        var delta = new JsonObject();
        if (content is not null)
        {
            delta["role"] = "assistant";
            delta["content"] = content;
        }
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

    private static ModelCompletionResult Failure(int status, string code)
    {
        byte[] body = JsonSerializer.SerializeToUtf8Bytes(new
        {
            error = new { type = "provider_cli_error", code },
        });
        return new ModelCompletionResult(status, body, "application/json", false);
    }

    private static int ClassifyStatus(string output)
    {
        string lower = output.ToLowerInvariant();
        if (lower.Contains("rate limit", StringComparison.Ordinal)
            || lower.Contains("quota", StringComparison.Ordinal)
            || lower.Contains("usage exhausted", StringComparison.Ordinal)) return 429;
        if (lower.Contains("unauthorized", StringComparison.Ordinal)
            || lower.Contains("authentication", StringComparison.Ordinal)
            || lower.Contains("login required", StringComparison.Ordinal)) return 401;
        return 502;
    }

    private static bool ContainsDroidCoreDowngrade(string output)
    {
        string lower = output.ToLowerInvariant();
        return lower.Contains("droid core", StringComparison.Ordinal)
            || lower.Contains("droid-core", StringComparison.Ordinal)
            || lower.Contains("standard usage runs out", StringComparison.Ordinal)
            || lower.Contains("standard usage is exhausted", StringComparison.Ordinal);
    }

    private static bool IsCodex(string vendor) =>
        string.Equals(vendor, "codex", StringComparison.OrdinalIgnoreCase);

    private static string? ReadString(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue(out string? result) ? result : null;
}
