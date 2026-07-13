using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.Presentation.Projects;

/// <summary>Portable request sent to the Tree-sitter JSONL parser.</summary>
public sealed record ProjectCodeParseRequest(
    string RequestId,
    string FilePath,
    string Language,
    string BlobSha,
    string Text,
    string? RootPath = null,
    string? Operation = null,
    ProjectCodeParsePosition? Position = null);

/// LSP source coordinates are zero-based, matching the parser wire protocol.
public sealed record ProjectCodeParsePosition(int Line, int Character);

public sealed record ProjectCodeParsedSymbol(
    string Name,
    string Kind,
    int StartLine,
    int EndLine,
    string ConfidenceTier,
    bool ShaMatch,
    string Parser);

public sealed record ProjectCodeParsedReference(
    string FilePath,
    int StartLine,
    int EndLine,
    int StartCharacter,
    int EndCharacter,
    string ConfidenceTier);

public sealed record ProjectCodeParseResponse(
    bool Ok,
    bool HasParseError,
    IReadOnlyList<ProjectCodeParsedSymbol> Symbols,
    IReadOnlyList<string> Errors,
    string Parser,
    bool ShaMatch,
    IReadOnlyList<ProjectCodeParsedReference>? References = null);

public interface IProjectCodeStaticParserClient
{
    Task<ProjectCodeParseResponse> ParseAsync(
        ProjectCodeParseRequest request,
        CancellationToken cancellationToken = default);
}

/// <summary>Deterministic parser seam for presentation and integration tests.</summary>
public sealed class DelegateProjectCodeStaticParserClient : IProjectCodeStaticParserClient
{
    private readonly Func<ProjectCodeParseRequest, CancellationToken, Task<ProjectCodeParseResponse>> _handler;

    public DelegateProjectCodeStaticParserClient(
        Func<ProjectCodeParseRequest, CancellationToken, Task<ProjectCodeParseResponse>> handler)
    {
        _handler = handler ?? throw new ArgumentNullException(nameof(handler));
    }

    public Task<ProjectCodeParseResponse> ParseAsync(
        ProjectCodeParseRequest request,
        CancellationToken cancellationToken = default) =>
        _handler(request, cancellationToken);
}

/// <summary>
/// Invokes the bundled project-code-static-parser without a shell. Each request
/// gets a bounded process so a crashed or wedged parser cannot poison the index.
/// </summary>
public sealed class JsonLinesProjectCodeStaticParserClient : IProjectCodeStaticParserClient
{
    private const int MaxTextBytes = 4 * 1024 * 1024;
    private const int MaxResponseBytes = 4 * 1024 * 1024;
    private readonly string _executablePath;
    private readonly IReadOnlyList<string> _arguments;
    private readonly TimeSpan _timeout;

    public JsonLinesProjectCodeStaticParserClient(
        string executablePath,
        IReadOnlyList<string>? arguments = null,
        TimeSpan? timeout = null)
    {
        if (string.IsNullOrWhiteSpace(executablePath))
        {
            throw new ArgumentException("A parser executable path is required.", nameof(executablePath));
        }

        _executablePath = Path.GetFullPath(executablePath);
        _arguments = arguments ?? Array.Empty<string>();
        _timeout = timeout ?? TimeSpan.FromSeconds(10);
        if (_timeout <= TimeSpan.Zero || _timeout > TimeSpan.FromMinutes(2))
        {
            throw new ArgumentOutOfRangeException(nameof(timeout));
        }
    }

    public async Task<ProjectCodeParseResponse> ParseAsync(
        ProjectCodeParseRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (string.IsNullOrWhiteSpace(request.FilePath) || string.IsNullOrWhiteSpace(request.Text))
        {
            throw new ArgumentException("Parser requests require a file path and source text.", nameof(request));
        }

        if (Encoding.UTF8.GetByteCount(request.Text) > MaxTextBytes)
        {
            throw new ProjectCodeParserException("source_too_large");
        }

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(_timeout);
        var startInfo = new ProcessStartInfo
        {
            FileName = _executablePath,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardInputEncoding = Encoding.UTF8,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (string argument in _arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        using Process process = StartProcess(startInfo);
        Task<string> stderrTask = process.StandardError.ReadToEndAsync(timeout.Token);
        try
        {
            string requestJson = JsonSerializer.Serialize(request, JsonOptions.Default);
            await process.StandardInput.WriteLineAsync(requestJson.AsMemory(), timeout.Token).ConfigureAwait(false);
            await process.StandardInput.FlushAsync(timeout.Token).ConfigureAwait(false);
            process.StandardInput.Close();

            string? responseLine = await process.StandardOutput.ReadLineAsync(timeout.Token).ConfigureAwait(false);
            if (responseLine is null)
            {
                string detail = await ReadStderrAsync(stderrTask).ConfigureAwait(false);
                throw new ProjectCodeParserException(string.IsNullOrWhiteSpace(detail)
                    ? "parser_empty_response"
                    : "parser_empty_response: " + detail.Trim());
            }

            if (Encoding.UTF8.GetByteCount(responseLine) > MaxResponseBytes)
            {
                throw new ProjectCodeParserException("parser_response_too_large");
            }

            ProjectCodeParserWireResponse? wire = JsonSerializer.Deserialize<ProjectCodeParserWireResponse>(
                responseLine,
                JsonOptions.Default);
            if (wire is null)
            {
                throw new ProjectCodeParserException("parser_invalid_response");
            }

            await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            return wire.ToResponse();
        }
        catch (OperationCanceledException) when (timeout.IsCancellationRequested)
        {
            Kill(process);
            throw new ProjectCodeParserException(cancellationToken.IsCancellationRequested
                ? "parser_cancelled"
                : "parser_timeout");
        }
        catch (JsonException error)
        {
            Kill(process);
            throw new ProjectCodeParserException("parser_invalid_response", error);
        }
        finally
        {
            Kill(process);
        }
    }

    public static string ComputeGitBlobSha(string text)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(text);
        byte[] header = Encoding.UTF8.GetBytes("blob " + bytes.Length + '\0');
        byte[] payload = new byte[header.Length + bytes.Length];
        Buffer.BlockCopy(header, 0, payload, 0, header.Length);
        Buffer.BlockCopy(bytes, 0, payload, header.Length, bytes.Length);
        return Convert.ToHexString(SHA1.HashData(payload)).ToLowerInvariant();
    }

    private static async Task<string> ReadStderrAsync(Task<string> stderrTask)
    {
        try
        {
            return await stderrTask.ConfigureAwait(false);
        }
        catch
        {
            return string.Empty;
        }
    }

    private static Process StartProcess(ProcessStartInfo startInfo)
    {
        try
        {
            return Process.Start(startInfo)
                ?? throw new ProjectCodeParserException("parser_start_failed");
        }
        catch (ProjectCodeParserException)
        {
            throw;
        }
        catch (Exception error)
        {
            throw new ProjectCodeParserException("parser_start_failed", error);
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
            // Best effort cleanup; the parser cannot survive the request scope.
        }
    }

    private static class JsonOptions
    {
        public static readonly JsonSerializerOptions Default = new()
        {
            PropertyNameCaseInsensitive = true,
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        };
    }

    private sealed record ProjectCodeParserWireResponse(
        bool Ok,
        bool HasParseError,
        List<ProjectCodeParserWireSymbol>? Symbols,
        List<string>? Errors,
        string? Language,
        string? BlobSha,
        bool ShaMatch,
        List<ProjectCodeParserWireReference>? References)
    {
        public ProjectCodeParseResponse ToResponse()
        {
            var symbols = new List<ProjectCodeParsedSymbol>();
            foreach (ProjectCodeParserWireSymbol symbol in Symbols ?? new List<ProjectCodeParserWireSymbol>())
            {
                symbols.Add(new ProjectCodeParsedSymbol(
                    symbol.Name ?? string.Empty,
                    symbol.Kind ?? "symbol",
                    symbol.StartLine + 1,
                    symbol.EndLine + 1,
                    symbol.ConfidenceTier ?? "static_tree_sitter",
                    symbol.Evidence?.ShaMatch ?? false,
                    symbol.Evidence?.Parser ?? "tree-sitter"));
            }

            var references = (References ?? new List<ProjectCodeParserWireReference>())
                .ConvertAll(reference => new ProjectCodeParsedReference(
                    reference.FilePath ?? string.Empty,
                    reference.StartLine,
                    reference.EndLine,
                    reference.StartCharacter,
                    reference.EndCharacter,
                    reference.ConfidenceTier ?? "exact_lsp"));

            return new ProjectCodeParseResponse(
                Ok,
                HasParseError,
                symbols,
                Errors ?? new List<string>(),
                symbols.Exists(symbol => string.Equals(symbol.Parser, "lsp", StringComparison.OrdinalIgnoreCase))
                    || references.Count > 0
                    ? "lsp"
                    : "tree-sitter",
                ShaMatch,
                references);
        }
    }

    private sealed record ProjectCodeParserWireSymbol(
        string? Name,
        string? Kind,
        int StartLine,
        int EndLine,
        string? ConfidenceTier,
        ProjectCodeParserWireEvidence? Evidence);

    private sealed record ProjectCodeParserWireEvidence(
        string? Parser,
        bool ShaMatch);

    private sealed record ProjectCodeParserWireReference(
        string? FilePath,
        int StartLine,
        int EndLine,
        int StartCharacter,
        int EndCharacter,
        string? ConfidenceTier);
}

public sealed class ProjectCodeParserException : Exception
{
    public ProjectCodeParserException(string message)
        : base(message)
    {
    }

    public ProjectCodeParserException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
