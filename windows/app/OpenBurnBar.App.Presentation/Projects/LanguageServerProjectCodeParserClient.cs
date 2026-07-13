using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.Presentation.Projects;

/// <summary>
/// Shell-free JSON-RPC language-server adapter for project symbols and
/// references. A server is scoped to one request so a crashed or wedged
/// language server cannot poison the long-lived index. Commands are supplied as
/// executable-plus-argument vectors; no shell interpolation is ever used.
/// </summary>
public sealed class LanguageServerProjectCodeParserClient : IProjectCodeStaticParserClient
{
    public const int DefaultMaxTextBytes = 4 * 1024 * 1024;
    public const int DefaultMaxResponseBytes = 4 * 1024 * 1024;

    private readonly IReadOnlyDictionary<string, IReadOnlyList<string>> _commands;
    private readonly TimeSpan _timeout;
    private readonly int _maxTextBytes;
    private readonly int _maxResponseBytes;

    public LanguageServerProjectCodeParserClient(
        IReadOnlyDictionary<string, IReadOnlyList<string>> commands,
        TimeSpan? timeout = null,
        int maxTextBytes = DefaultMaxTextBytes,
        int maxResponseBytes = DefaultMaxResponseBytes)
    {
        ArgumentNullException.ThrowIfNull(commands);
        if (commands.Count == 0)
        {
            throw new ArgumentException("At least one language-server command is required.", nameof(commands));
        }

        _commands = commands.ToDictionary(
            pair => NormalizeLanguage(pair.Key),
            pair => ValidateCommand(pair.Value),
            StringComparer.OrdinalIgnoreCase);
        _timeout = timeout ?? TimeSpan.FromSeconds(10);
        if (_timeout <= TimeSpan.Zero || _timeout > TimeSpan.FromMinutes(2))
        {
            throw new ArgumentOutOfRangeException(nameof(timeout));
        }

        if (maxTextBytes is < 1 or > 32 * 1024 * 1024)
        {
            throw new ArgumentOutOfRangeException(nameof(maxTextBytes));
        }

        if (maxResponseBytes is < 1 or > 32 * 1024 * 1024)
        {
            throw new ArgumentOutOfRangeException(nameof(maxResponseBytes));
        }

        _maxTextBytes = maxTextBytes;
        _maxResponseBytes = maxResponseBytes;
    }

    public async Task<ProjectCodeParseResponse> ParseAsync(
        ProjectCodeParseRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (string.IsNullOrWhiteSpace(request.FilePath) || string.IsNullOrWhiteSpace(request.Text))
        {
            throw new ArgumentException("Language-server requests require a file path and source text.", nameof(request));
        }

        string language = NormalizeLanguage(request.Language);
        if (!_commands.TryGetValue(language, out IReadOnlyList<string>? command))
        {
            throw new ProjectCodeParserException("lsp_unavailable");
        }

        if (Encoding.UTF8.GetByteCount(request.Text) > _maxTextBytes)
        {
            throw new ProjectCodeParserException("lsp_source_too_large");
        }

        string root = CanonicalRoot(request.RootPath);
        string filePath = ResolveContainedPath(root, request.FilePath);
        string uri = new Uri(filePath).AbsoluteUri;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(_timeout);

        Process? process = null;
        try
        {
            process = StartProcess(command);
            Task<string> stderrTask = ReadStderrBoundedAsync(process.StandardError, timeout.Token);
            int nextId = 1;

            await WriteRequestAsync(
                process.StandardInput.BaseStream,
                nextId,
                "initialize",
                new
                {
                    processId = Environment.ProcessId,
                    rootUri = new Uri(root).AbsoluteUri,
                    capabilities = new { },
                    workspaceFolders = new[] { new { uri = new Uri(root).AbsoluteUri, name = Path.GetFileName(root) } },
                },
                timeout.Token).ConfigureAwait(false);
            using JsonDocument initialize = await ReadResponseAsync(
                process.StandardOutput.BaseStream,
                nextId++,
                timeout.Token).ConfigureAwait(false);
            EnsureSuccessfulResponse(initialize, "lsp_initialize_failed");

            await WriteNotificationAsync(process.StandardInput.BaseStream, "initialized", new { }, timeout.Token)
                .ConfigureAwait(false);
            await WriteNotificationAsync(
                process.StandardInput.BaseStream,
                "textDocument/didOpen",
                new
                {
                    textDocument = new
                    {
                        uri,
                        languageId = language,
                        version = 1,
                        text = request.Text,
                    },
                },
                timeout.Token).ConfigureAwait(false);

            bool references = string.Equals(request.Operation, "references", StringComparison.OrdinalIgnoreCase);
            int operationId = nextId++;
            object parameters = references
                ? new
                {
                    textDocument = new { uri },
                    position = new
                    {
                        line = Math.Max(0, request.Position?.Line ?? 0),
                        character = Math.Max(0, request.Position?.Character ?? 0),
                    },
                    context = new { includeDeclaration = true },
                }
                : new { textDocument = new { uri } };
            using JsonDocument operation = await ReadOperationAsync(
                process.StandardInput.BaseStream,
                process.StandardOutput.BaseStream,
                operationId,
                references ? "textDocument/references" : "textDocument/documentSymbol",
                parameters,
                timeout.Token).ConfigureAwait(false);
            EnsureSuccessfulResponse(operation, "lsp_operation_failed");

            ProjectCodeParseResponse response = references
                ? ParseReferences(operation, root, request)
                : ParseSymbols(operation, request);

            int shutdownId = nextId++;
            await WriteRequestAsync(process.StandardInput.BaseStream, shutdownId, "shutdown", null, timeout.Token)
                .ConfigureAwait(false);
            using JsonDocument shutdown = await ReadResponseAsync(
                process.StandardOutput.BaseStream,
                shutdownId,
                timeout.Token).ConfigureAwait(false);
            EnsureSuccessfulResponse(shutdown, "lsp_shutdown_failed");
            await WriteNotificationAsync(process.StandardInput.BaseStream, "exit", null, timeout.Token)
                .ConfigureAwait(false);
            process.StandardInput.Close();
            await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            _ = await stderrTask.ConfigureAwait(false);
            return response;
        }
        catch (OperationCanceledException) when (timeout.IsCancellationRequested)
        {
            throw new ProjectCodeParserException(cancellationToken.IsCancellationRequested
                ? "lsp_cancelled"
                : "lsp_timeout");
        }
        finally
        {
            if (process is not null)
            {
                Kill(process);
                process.Dispose();
            }
        }
    }

    private static ProjectCodeParseResponse ParseSymbols(JsonDocument document, ProjectCodeParseRequest request)
    {
        JsonElement result = ResultElement(document, "lsp_symbols_invalid");
        var symbols = new List<ProjectCodeParsedSymbol>();
        bool shaMatch = string.Equals(
            JsonLinesProjectCodeStaticParserClient.ComputeGitBlobSha(request.Text),
            request.BlobSha,
            StringComparison.OrdinalIgnoreCase);
        if (result.ValueKind == JsonValueKind.Array)
        {
            foreach (JsonElement symbol in result.EnumerateArray())
            {
                AddSymbols(symbol, symbols, shaMatch);
            }
        }

        return new ProjectCodeParseResponse(
            Ok: true,
            HasParseError: false,
            Symbols: symbols,
            Errors: Array.Empty<string>(),
            Parser: "lsp",
            ShaMatch: shaMatch,
            References: Array.Empty<ProjectCodeParsedReference>());
    }

    private static ProjectCodeParseResponse ParseReferences(
        JsonDocument document,
        string root,
        ProjectCodeParseRequest request)
    {
        JsonElement result = ResultElement(document, "lsp_references_invalid");
        var references = new List<ProjectCodeParsedReference>();
        if (result.ValueKind == JsonValueKind.Array)
        {
            foreach (JsonElement location in result.EnumerateArray())
            {
                if (!TryParseLocation(location, root, out ProjectCodeParsedReference? reference)
                    || reference is null)
                {
                    continue;
                }

                references.Add(reference);
            }
        }

        bool shaMatch = string.Equals(
            JsonLinesProjectCodeStaticParserClient.ComputeGitBlobSha(request.Text),
            request.BlobSha,
            StringComparison.OrdinalIgnoreCase);
        return new ProjectCodeParseResponse(
            Ok: true,
            HasParseError: false,
            Symbols: Array.Empty<ProjectCodeParsedSymbol>(),
            Errors: Array.Empty<string>(),
            Parser: "lsp",
            ShaMatch: shaMatch,
            References: references);
    }

    private static void AddSymbols(
        JsonElement element,
        ICollection<ProjectCodeParsedSymbol> symbols,
        bool shaMatch)
    {
        if (element.ValueKind != JsonValueKind.Object
            || !element.TryGetProperty("name", out JsonElement nameElement)
            || nameElement.ValueKind != JsonValueKind.String
            || string.IsNullOrWhiteSpace(nameElement.GetString())
            || !TryReadRange(element, out LspRange range))
        {
            return;
        }

        int kind = element.TryGetProperty("kind", out JsonElement kindElement) && kindElement.TryGetInt32(out int parsedKind)
            ? parsedKind
            : 13;
        symbols.Add(new ProjectCodeParsedSymbol(
            nameElement.GetString()!,
            SymbolKindName(kind),
            range.Start.Line,
            range.End.Line,
            "exact_lsp",
            ShaMatch: shaMatch,
            Parser: "lsp"));

        if (element.TryGetProperty("children", out JsonElement children)
            && children.ValueKind == JsonValueKind.Array)
        {
            foreach (JsonElement child in children.EnumerateArray())
            {
                AddSymbols(child, symbols, shaMatch);
            }
        }
    }

    private static bool TryParseLocation(
        JsonElement element,
        string root,
        out ProjectCodeParsedReference? reference)
    {
        reference = null;
        if (element.ValueKind != JsonValueKind.Object
            || (!element.TryGetProperty("uri", out JsonElement uriElement)
                && !element.TryGetProperty("targetUri", out uriElement))
            || uriElement.ValueKind != JsonValueKind.String
            || (!TryReadRange(element, out LspRange range)
                && (!element.TryGetProperty("targetRange", out JsonElement targetRange)
                    || !TryReadRangeObject(targetRange, out range))))
        {
            return false;
        }

        string? uri = uriElement.GetString();
        if (string.IsNullOrWhiteSpace(uri) || !Uri.TryCreate(uri, UriKind.Absolute, out Uri? parsedUri)
            || !string.Equals(parsedUri.Scheme, Uri.UriSchemeFile, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        string path;
        try
        {
            path = ResolveContainedPath(root, parsedUri.LocalPath);
        }
        catch (ArgumentException)
        {
            return false;
        }

        reference = new ProjectCodeParsedReference(
            Path.GetRelativePath(root, path).Replace('\\', '/'),
            range.Start.Line,
            range.End.Line,
            range.Start.Character,
            range.End.Character,
            "exact_lsp");
        return true;
    }

    private static JsonElement ResultElement(JsonDocument document, string errorCode)
    {
        if (!document.RootElement.TryGetProperty("result", out JsonElement result)
            || result.ValueKind == JsonValueKind.Undefined)
        {
            throw new ProjectCodeParserException(errorCode);
        }

        return result;
    }

    private static bool TryReadRange(JsonElement element, out LspRange range)
    {
        range = default;
        if (!element.TryGetProperty("range", out JsonElement rangeElement)
            || !TryReadRangeObject(rangeElement, out range))
        {
            return false;
        }

        return true;
    }

    private static bool TryReadRangeObject(JsonElement element, out LspRange range)
    {
        range = default;
        if (element.ValueKind != JsonValueKind.Object
            || !TryReadPosition(element, "start", out LspPosition start)
            || !TryReadPosition(element, "end", out LspPosition end))
        {
            return false;
        }

        range = new LspRange(start, end);
        return true;
    }

    private static bool TryReadPosition(JsonElement parent, string name, out LspPosition position)
    {
        position = default;
        if (!parent.TryGetProperty(name, out JsonElement element)
            || element.ValueKind != JsonValueKind.Object
            || !element.TryGetProperty("line", out JsonElement lineElement)
            || !lineElement.TryGetInt32(out int line)
            || !element.TryGetProperty("character", out JsonElement characterElement)
            || !characterElement.TryGetInt32(out int character))
        {
            return false;
        }

        position = new LspPosition(Math.Max(1, line + 1), Math.Max(0, character));
        return true;
    }

    private static string SymbolKindName(int kind) => kind switch
    {
        2 => "module",
        3 => "namespace",
        4 => "package",
        5 => "class",
        6 => "method",
        7 => "property",
        8 => "field",
        9 => "constructor",
        10 => "enum",
        11 => "interface",
        12 => "function",
        13 => "variable",
        14 => "constant",
        23 => "struct",
        24 => "event",
        25 => "operator",
        26 => "type_parameter",
        _ => "symbol",
    };

    private async Task<JsonDocument> ReadOperationAsync(
        Stream input,
        Stream output,
        int id,
        string method,
        object parameters,
        CancellationToken cancellationToken)
    {
        await WriteRequestAsync(input, id, method, parameters, cancellationToken).ConfigureAwait(false);
        return await ReadResponseAsync(output, id, cancellationToken).ConfigureAwait(false);
    }

    private async Task<JsonDocument> ReadResponseAsync(Stream output, int expectedId, CancellationToken cancellationToken)
    {
        while (true)
        {
            byte[]? frame = await ReadFrameAsync(output, _maxResponseBytes, cancellationToken).ConfigureAwait(false);
            if (frame is null)
            {
                throw new ProjectCodeParserException("lsp_empty_response");
            }

            JsonDocument document;
            try
            {
                document = JsonDocument.Parse(frame);
            }
            catch (JsonException exception)
            {
                throw new ProjectCodeParserException("lsp_invalid_response", exception);
            }

            if (document.RootElement.TryGetProperty("id", out JsonElement idElement)
                && idElement.TryGetInt32(out int actualId)
                && actualId == expectedId)
            {
                return document;
            }

            document.Dispose();
        }
    }

    private static void EnsureSuccessfulResponse(JsonDocument document, string errorCode)
    {
        if (document.RootElement.TryGetProperty("error", out JsonElement error)
            && error.ValueKind != JsonValueKind.Null)
        {
            string detail = error.TryGetProperty("message", out JsonElement message)
                && message.ValueKind == JsonValueKind.String
                ? message.GetString() ?? errorCode
                : errorCode;
            throw new ProjectCodeParserException(errorCode + ": " + detail[..Math.Min(detail.Length, 256)]);
        }
    }

    private static async Task WriteRequestAsync(
        Stream input,
        int id,
        string method,
        object? parameters,
        CancellationToken cancellationToken)
    {
        await WriteFrameAsync(input, new { jsonrpc = "2.0", id, method, @params = parameters }, cancellationToken)
            .ConfigureAwait(false);
    }

    private static Task WriteNotificationAsync(
        Stream input,
        string method,
        object? parameters,
        CancellationToken cancellationToken) =>
        WriteFrameAsync(input, new { jsonrpc = "2.0", method, @params = parameters }, cancellationToken);

    private static async Task WriteFrameAsync(Stream input, object payload, CancellationToken cancellationToken)
    {
        byte[] body = JsonSerializer.SerializeToUtf8Bytes(payload, new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        });
        byte[] header = Encoding.ASCII.GetBytes($"Content-Length: {body.Length}\r\n\r\n");
        await input.WriteAsync(header.AsMemory(), cancellationToken).ConfigureAwait(false);
        await input.WriteAsync(body.AsMemory(), cancellationToken).ConfigureAwait(false);
        await input.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    private static async Task<byte[]?> ReadFrameAsync(Stream output, int maxResponseBytes, CancellationToken cancellationToken)
    {
        var header = new List<byte>(128);
        var one = new byte[1];
        while (true)
        {
            int read = await output.ReadAsync(one.AsMemory(), cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                return null;
            }

            header.Add(one[0]);
            if (header.Count > 16 * 1024)
            {
                throw new ProjectCodeParserException("lsp_headers_too_large");
            }

            int count = header.Count;
            if (count >= 4
                && header[count - 4] == '\r'
                && header[count - 3] == '\n'
                && header[count - 2] == '\r'
                && header[count - 1] == '\n')
            {
                break;
            }
        }

        string headerText = Encoding.ASCII.GetString(header.ToArray(), 0, header.Count - 4);
        int? contentLength = null;
        foreach (string line in headerText.Split("\r\n", StringSplitOptions.RemoveEmptyEntries))
        {
            int separator = line.IndexOf(':');
            if (separator <= 0 || !line[..separator].Equals("Content-Length", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            if (!int.TryParse(line[(separator + 1)..].Trim(), out int parsedLength) || parsedLength < 0)
            {
                throw new ProjectCodeParserException("lsp_invalid_content_length");
            }

            contentLength = parsedLength;
        }

        if (contentLength is null)
        {
            throw new ProjectCodeParserException("lsp_missing_content_length");
        }

        if (contentLength.Value > maxResponseBytes)
        {
            throw new ProjectCodeParserException("lsp_response_too_large");
        }

        byte[] body = new byte[contentLength.Value];
        int offset = 0;
        while (offset < body.Length)
        {
            int read = await output.ReadAsync(body.AsMemory(offset), cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                throw new ProjectCodeParserException("lsp_truncated_response");
            }

            offset += read;
        }

        return body;
    }

    private static async Task<string> ReadStderrBoundedAsync(StreamReader reader, CancellationToken cancellationToken)
    {
        var buffer = new char[4096];
        var output = new StringBuilder();
        while (true)
        {
            int read = await reader.ReadAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                break;
            }

            if (output.Length < 64 * 1024)
            {
                output.Append(buffer, 0, Math.Min(read, 64 * 1024 - output.Length));
            }
        }

        return output.ToString();
    }

    private static Process StartProcess(IReadOnlyList<string> command)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = command[0],
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardInputEncoding = Encoding.UTF8,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        for (int index = 1; index < command.Count; index++)
        {
            startInfo.ArgumentList.Add(command[index]);
        }

        try
        {
            return Process.Start(startInfo)
                ?? throw new ProjectCodeParserException("lsp_start_failed");
        }
        catch (ProjectCodeParserException)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw new ProjectCodeParserException("lsp_start_failed", exception);
        }
    }

    private static void Kill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch
        {
            // Best effort cleanup; timeout/cancellation remains fail-closed.
        }
    }

    private static IReadOnlyList<string> ValidateCommand(IReadOnlyList<string> command)
    {
        if (command is null || command.Count == 0 || string.IsNullOrWhiteSpace(command[0]))
        {
            throw new ArgumentException("Each language-server command needs an executable.", nameof(command));
        }

        if (command.Any(argument => argument is null || argument.Length > 4096))
        {
            throw new ArgumentException("Language-server arguments are invalid or too large.", nameof(command));
        }

        return command.ToArray();
    }

    private static string NormalizeLanguage(string? language)
        => (language ?? string.Empty).Trim().TrimStart('.').ToLowerInvariant();

    private static string CanonicalRoot(string? root)
    {
        if (string.IsNullOrWhiteSpace(root))
        {
            throw new ArgumentException("A project root is required for language-server requests.", nameof(root));
        }

        string path = Path.GetFullPath(root);
        if (!Directory.Exists(path))
        {
            throw new ArgumentException("The language-server project root does not exist.", nameof(root));
        }

        string? filesystemRoot = Path.GetPathRoot(path);
        return string.Equals(path, filesystemRoot, StringComparison.OrdinalIgnoreCase)
            ? path
            : path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
    }

    private static string ResolveContainedPath(string root, string requestedPath)
    {
        string fullPath = Path.GetFullPath(
            Path.IsPathRooted(requestedPath) ? requestedPath : Path.Combine(root, requestedPath));
        string prefix = root.EndsWith(Path.DirectorySeparatorChar)
            ? root
            : root + Path.DirectorySeparatorChar;
        if (!fullPath.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
            && !string.Equals(fullPath, root, StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException("The language-server file must be inside the project root.", nameof(requestedPath));
        }

        return fullPath;
    }

    private readonly record struct LspPosition(int Line, int Character);

    private readonly record struct LspRange(LspPosition Start, LspPosition End);
}
