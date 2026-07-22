using System.Diagnostics;
using System.Text;
using OpenBurnBar.App.Chat;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;

namespace OpenBurnBar.App.Gateway;

/// <summary>
/// Production provider-CLI boundary. Executables must be approved by path and
/// digest, arguments never pass through a shell, output is bounded, and timeout
/// or cancellation terminates the entire child tree.
/// </summary>
public sealed class WindowsProviderCliProcessRunner : IProviderCliProcessRunner
{
    public const int MaximumOutputBytesPerStream = 16 * 1024 * 1024;
    public const int MaximumArgumentCharacters = 1024 * 1024;
    private static readonly TimeSpan MaximumTimeout = TimeSpan.FromMinutes(10);
    private readonly IChatExecutableInventory _inventory;

    public WindowsProviderCliProcessRunner(IChatExecutableInventory? inventory = null)
    {
        _inventory = inventory ?? ProtectedChatExecutableInventoryStore.CreateDefault();
    }

    public async Task<ProviderCliProcessResult> RunAsync(
        ProviderCliProcessRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        Validate(request);

        ChatExecutableResolution executable = _inventory.LoadCatalog().Resolve(request.ExecutableId);
        ProcessStartInfo startInfo = ChildProcessLaunchPolicy.CreateStartInfo(
            ChildProcessProfile.Gateway,
            executable.Path,
            request.Arguments,
            request.WorkingDirectory,
            redirectStandardInput: request.StandardInput is not null,
            redirectStandardOutput: true,
            redirectStandardError: true,
            standardInputEncoding: request.StandardInput is null ? null : Encoding.UTF8,
            standardOutputEncoding: Encoding.UTF8,
            standardErrorEncoding: Encoding.UTF8,
            requiredEnvironment: request.RequiredEnvironment.Select(pair =>
                new KeyValuePair<string, string?>(pair.Key, pair.Value)));

        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        linked.CancelAfter(request.Timeout);
        using Process process = ChildProcessLaunchPolicy.Start(startInfo, ChildProcessProfile.Gateway);
        Task<string> stdoutTask = ReadBoundedAsync(
            process.StandardOutput.BaseStream,
            process,
            linked.Token);
        Task<string> stderrTask = ReadBoundedAsync(
            process.StandardError.BaseStream,
            process,
            linked.Token);

        try
        {
            if (request.StandardInput is not null)
            {
                await process.StandardInput
                    .WriteAsync(request.StandardInput.AsMemory(), linked.Token)
                    .ConfigureAwait(false);
                process.StandardInput.Close();
            }

            await process.WaitForExitAsync(linked.Token).ConfigureAwait(false);
            string[] output = await Task.WhenAll(stdoutTask, stderrTask).ConfigureAwait(false);
            return new ProviderCliProcessResult(process.ExitCode, output[0], output[1]);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            Kill(process);
            throw new TimeoutException("Provider CLI exceeded its execution timeout.");
        }
        catch
        {
            Kill(process);
            throw;
        }
    }

    private static async Task<string> ReadBoundedAsync(
        Stream stream,
        Process process,
        CancellationToken cancellationToken)
    {
        byte[] buffer = new byte[16 * 1024];
        using var output = new MemoryStream();
        while (true)
        {
            int read = await stream.ReadAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false);
            if (read == 0) break;
            if (output.Length + read > MaximumOutputBytesPerStream)
            {
                Kill(process);
                throw new InvalidDataException("Provider CLI output exceeded the bounded capture limit.");
            }
            output.Write(buffer, 0, read);
        }

        return new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true)
            .GetString(output.ToArray());
    }

    private static void Validate(ProviderCliProcessRequest request)
    {
        ArgumentNullException.ThrowIfNull(request.Arguments);
        ArgumentNullException.ThrowIfNull(request.RequiredEnvironment);
        if (request.ExecutableId is not ("codex" or "droid"))
        {
            throw new InvalidOperationException("Provider CLI executable identity is not supported.");
        }
        if (request.Timeout <= TimeSpan.Zero || request.Timeout > MaximumTimeout)
        {
            throw new ArgumentOutOfRangeException(nameof(request), "Provider CLI timeout is outside policy.");
        }
        if (!Path.IsPathFullyQualified(request.WorkingDirectory)
            || !Directory.Exists(request.WorkingDirectory))
        {
            throw new DirectoryNotFoundException("Provider CLI working directory is unavailable.");
        }
        long argumentCharacters = request.Arguments.Sum(argument => (long)argument.Length);
        if (request.Arguments.Count > 256 || argumentCharacters > MaximumArgumentCharacters)
        {
            throw new ArgumentException("Provider CLI argument vector exceeds policy.", nameof(request));
        }

        if (request.ExecutableId == "codex")
        {
            ValidateCodexContract(request);
        }
        else
        {
            ValidateFactoryContract(request);
        }
    }

    private static void ValidateCodexContract(ProviderCliProcessRequest request)
    {
        string[] arguments = request.Arguments.ToArray();
        string[] prefix =
        {
            "exec", "--json", "--ephemeral", "--skip-git-repo-check",
            "-c", "model_reasoning_effort=\"high\"",
        };
        string[] suffix =
        {
            "--sandbox", "read-only", "--ignore-user-config", "--ignore-rules", "-",
        };
        bool withoutModel = arguments.Length == prefix.Length + suffix.Length
            && arguments[..prefix.Length].SequenceEqual(prefix, StringComparer.Ordinal)
            && arguments[prefix.Length..].SequenceEqual(suffix, StringComparer.Ordinal);
        bool withModel = arguments.Length == prefix.Length + suffix.Length + 2
            && arguments[..prefix.Length].SequenceEqual(prefix, StringComparer.Ordinal)
            && arguments[prefix.Length] == "-m"
            && !string.IsNullOrWhiteSpace(arguments[prefix.Length + 1])
            && arguments[(prefix.Length + 2)..].SequenceEqual(suffix, StringComparer.Ordinal);
        if (!withoutModel && !withModel)
        {
            throw new InvalidOperationException("Codex provider arguments do not match the reviewed contract.");
        }
        if (string.IsNullOrWhiteSpace(request.StandardInput)
            || request.StandardInput.Length > ProviderCliModelCompletionExecutor.MaximumPromptCharacters)
        {
            throw new InvalidOperationException("Codex provider stdin is outside the reviewed contract.");
        }
        if (request.RequiredEnvironment.Count > 1
            || request.RequiredEnvironment.Any(pair =>
                !string.Equals(pair.Key, "OPENAI_API_KEY", StringComparison.OrdinalIgnoreCase)
                || string.IsNullOrWhiteSpace(pair.Value)))
        {
            throw new InvalidOperationException("Codex provider environment is outside the reviewed contract.");
        }
    }

    private static void ValidateFactoryContract(ProviderCliProcessRequest request)
    {
        string[] arguments = request.Arguments.ToArray();
        bool discovery = arguments.SequenceEqual(new[] { "exec", "--help" }, StringComparer.Ordinal);
        if (discovery)
        {
            if (request.StandardInput is not null
                || request.RequiredEnvironment.Count != 1
                || !request.RequiredEnvironment.TryGetValue("FACTORY_API_KEY", out string? discoveryKey)
                || string.IsNullOrWhiteSpace(discoveryKey))
            {
                throw new InvalidOperationException("Factory discovery environment is outside the reviewed contract.");
            }
            return;
        }

        string expectedPrompt = Path.Combine(request.WorkingDirectory, "prompt.txt");
        bool validArguments = arguments.Length == 11
            && arguments[0] == "exec"
            && arguments[1] == "--model"
            && !string.IsNullOrWhiteSpace(arguments[2])
            && arguments[3] == "--output-format"
            && arguments[4] == "json"
            && arguments[5] == "--cwd"
            && PathsEqual(arguments[6], request.WorkingDirectory)
            && arguments[7] == "--disabled-tools"
            && arguments[8] == "ApplyPatch,execute-cli"
            && arguments[9] == "-f"
            && PathsEqual(arguments[10], expectedPrompt);
        if (!validArguments || request.StandardInput is not null)
        {
            throw new InvalidOperationException("Factory provider arguments do not match the reviewed contract.");
        }
        if (request.RequiredEnvironment.Count != 2
            || !request.RequiredEnvironment.TryGetValue("FACTORY_API_KEY", out string? apiKey)
            || string.IsNullOrWhiteSpace(apiKey)
            || !request.RequiredEnvironment.TryGetValue("OPENBURNBAR_FACTORY_STRICT_STANDARD", out string? strict)
            || strict != "1")
        {
            throw new InvalidOperationException("Factory provider environment is outside the reviewed contract.");
        }
    }

    private static bool PathsEqual(string left, string right) =>
        string.Equals(
            Path.GetFullPath(left),
            Path.GetFullPath(right),
            OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    private static void Kill(Process process)
    {
        try
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
        }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            // The process exited between the state check and termination request.
        }
    }
}
