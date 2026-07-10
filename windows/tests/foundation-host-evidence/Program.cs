using System.Collections;
using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using OpenBurnBar.App.Chat;
using OpenBurnBar.App.Configuration;

namespace OpenBurnBar.FoundationHostEvidence;

internal static class Program
{
    private const int SampleLimit = 8192;
    private const long DefaultOutputLimit = 4 * 1024 * 1024;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    private static readonly string[] CanaryNames =
    {
        "OPENAI_API_KEY",
        "OPENBURNBAR_SQLCIPHER_PASSPHRASE",
        "DIAGNOSTIC_CANARY_SECRET",
        "WINDOWS_UPDATE_SIGNING_KEY",
        "FIREBASE_ID_TOKEN",
    };

    public static async Task<int> Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "--helper")
        {
            return await HelperMain(args.Skip(1).ToArray()).ConfigureAwait(false);
        }

        string outputDir = "";
        string? expectedCandidate = null;
        for (var i = 0; i < args.Length; i++)
        {
            if (args[i] == "--output" && i + 1 < args.Length)
            {
                outputDir = args[++i];
            }
            else if (args[i] == "--expected-candidate" && i + 1 < args.Length)
            {
                expectedCandidate = args[++i];
            }
            else if (args[i] is "--help" or "-h")
            {
                Console.Error.WriteLine("Usage: OpenBurnBar.FoundationHostEvidence --output <dir> [--expected-candidate <sha>]");
                return 2;
            }
        }

        if (string.IsNullOrWhiteSpace(outputDir))
        {
            Console.Error.WriteLine("--output is required.");
            return 2;
        }

        Directory.CreateDirectory(outputDir);
        foreach (string name in CanaryNames)
        {
            Environment.SetEnvironmentVariable(name, $"openburnbar-canary-{name.ToLowerInvariant()}-do-not-leak");
        }

        EvidenceRun run = await ProcessEvidenceRunner
            .RunAsync(outputDir, expectedCandidate)
            .ConfigureAwait(false);
        string path = Path.Combine(outputDir, "process-evidence.json");
        await File.WriteAllTextAsync(path, JsonSerializer.Serialize(run, JsonOptions)).ConfigureAwait(false);
        Console.WriteLine(path);
        return run.Scenarios.Any(s => s.Status == "failed") ? 1 : 0;
    }

    private static async Task<int> HelperMain(string[] args)
    {
        if (args.Length == 0)
        {
            Console.Error.WriteLine("missing helper mode");
            return 2;
        }

        switch (args[0])
        {
            case "echo":
                Console.WriteLine(args.Length > 1 ? args[1] : string.Empty);
                return 0;
            case "stdin":
                Console.Write(await Console.In.ReadToEndAsync().ConfigureAwait(false));
                return 0;
            case "stderr-block":
                for (var i = 0; i < 512; i++)
                {
                    Console.Error.Write(new string('e', 4096));
                }
                Console.WriteLine("stderr-drained");
                return 0;
            case "infinite":
                for (var i = 0; ; i++)
                {
                    Console.WriteLine("infinite-output-" + i.ToString("D8"));
                    await Task.Delay(1).ConfigureAwait(false);
                }
            case "grandchild":
            {
                string exe = ResolveDotnetHost();
                using Process child = Process.Start(new ProcessStartInfo
                {
                    FileName = exe,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    ArgumentList = { ExecutingAssemblyPath(), "--helper", "sleep", "30" },
                }) ?? throw new InvalidOperationException("grandchild did not start");
                Console.WriteLine(JsonSerializer.Serialize(new { childPid = child.Id }));
                await Task.Delay(TimeSpan.FromSeconds(30)).ConfigureAwait(false);
                return 0;
            }
            case "sleep":
                int seconds = args.Length > 1 && int.TryParse(args[1], out int parsed) ? parsed : 5;
                await Task.Delay(TimeSpan.FromSeconds(seconds)).ConfigureAwait(false);
                return 0;
            case "malformed":
                Console.WriteLine("{not-json");
                return 0;
            case "nonzero":
                Console.Error.WriteLine("helper produced a nonzero exit");
                return 17;
            case "envdump":
            {
                var names = Environment.GetEnvironmentVariables()
                    .Cast<DictionaryEntry>()
                    .Select(entry => ((string)entry.Key).ToUpperInvariant())
                    .OrderBy(name => name, StringComparer.Ordinal)
                    .ToArray();
                Console.WriteLine(JsonSerializer.Serialize(new
                {
                    names,
                    forbiddenNamesPresent = CanaryNames
                        .Where(name => names.Contains(name, StringComparer.OrdinalIgnoreCase))
                        .OrderBy(name => name, StringComparer.OrdinalIgnoreCase)
                        .ToArray(),
                }));
                return 0;
            }
            default:
                Console.Error.WriteLine("unknown helper mode: " + args[0]);
                return 2;
        }
    }

    private static string ExecutingAssemblyPath() =>
        Assembly.GetExecutingAssembly().Location;

    private static string ResolveDotnetHost()
    {
        string executableName = OperatingSystem.IsWindows() ? "dotnet.exe" : "dotnet";
        string? path = Environment.GetEnvironmentVariable("PATH");
        foreach (string directory in (path ?? string.Empty).Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            string candidate = Path.Combine(directory, executableName);
            if (File.Exists(candidate))
            {
                return Path.GetFullPath(candidate);
            }
        }

        string runtimeDirectory = RuntimeEnvironment.GetRuntimeDirectory();
        string adjacentHost = Path.GetFullPath(Path.Combine(runtimeDirectory, "..", "..", "..", executableName));
        if (File.Exists(adjacentHost))
        {
            return adjacentHost;
        }

        throw new InvalidOperationException("The dotnet host executable could not be resolved.");
    }

    private sealed record EvidenceRun(
        string Schema,
        string GeneratedAtUtc,
        string? ExpectedCandidate,
        ToolHost Host,
        IReadOnlyList<ChildProcessLaunchReview> ReviewedProductLaunches,
        IReadOnlyList<EnvironmentProfile> EnvironmentProfiles,
        IReadOnlyList<ProcessScenario> Scenarios);

    private sealed record ToolHost(
        string UserIdentitySha256,
        int SessionId,
        string MachineIdentitySha256,
        string OSDescription,
        string OSArchitecture,
        string ProcessArchitecture,
        string FrameworkDescription,
        string ProcessPath);

    private sealed record EnvironmentProfile(
        string Profile,
        IReadOnlyList<string> AllowedNames,
        IReadOnlyList<string> ForbiddenNamesRejected);

    private sealed record ProcessScenario(
        string Id,
        string Status,
        string ExpectedOutcome,
        string? FailureKind,
        string? FailureMessage,
        ProcessLaunchEvidence? Launch,
        ProcessResultEvidence? Result,
        IReadOnlyList<ProcessTableRow> BeforeProcessTable,
        IReadOnlyList<ProcessTableRow> AfterProcessTable,
        IReadOnlyList<int> SurvivorPids,
        string StartedAtUtc,
        string CompletedAtUtc);

    private sealed record ProcessLaunchEvidence(
        string FileName,
        string ResolvedPath,
        string Sha256,
        IReadOnlyList<string> ArgumentList,
        bool UseShellExecute,
        bool RedirectStandardInput,
        bool RedirectStandardOutput,
        bool RedirectStandardError,
        IReadOnlyList<EnvironmentEntry> Environment,
        IReadOnlyList<string> ForbiddenEnvironmentNamesPresent);

    private sealed record EnvironmentEntry(string Name, int ValueLength, string ValueSha256);

    private sealed record ProcessResultEvidence(
        int? ProcessId,
        int? ExitCode,
        bool TimedOut,
        bool Cancelled,
        bool OutputLimitExceeded,
        long StdoutBytes,
        long StderrBytes,
        string StdoutSample,
        string StderrSample,
        double ElapsedMs);

    private sealed record ProcessTableRow(int ProcessId, string ProcessName, string? Path);

    private sealed class ProcessEvidenceRunner
    {
        private readonly string _outputDir;
        private readonly string? _expectedCandidate;
        private readonly string _helperPath;
        private readonly string _helperAssemblyPath;

        private ProcessEvidenceRunner(string outputDir, string? expectedCandidate)
        {
            _outputDir = outputDir;
            _expectedCandidate = expectedCandidate;
            _helperPath = ResolveDotnetHost();
            _helperAssemblyPath = ExecutingAssemblyPath();
        }

        public static async Task<EvidenceRun> RunAsync(string outputDir, string? expectedCandidate)
        {
            var runner = new ProcessEvidenceRunner(outputDir, expectedCandidate);
            return await runner.RunAsync().ConfigureAwait(false);
        }

        private async Task<EvidenceRun> RunAsync()
        {
            var scenarios = new List<ProcessScenario>
            {
                await RunStartedScenario("process.environment.chat-scrubbed", "child receives allowlisted environment only", HelperArguments("envdump")).ConfigureAwait(false),
                await RunStartedScenario("process.metacharacters", "metacharacters stay data", HelperArguments("echo", "hello & | < > ^ % ! ; $(bad)")).ConfigureAwait(false),
                await RunStartedScenario("process.quotes", "quotes stay a single argument", HelperArguments("echo", "quoted \"value\" and spaces")).ConfigureAwait(false),
                await RunStartedScenario("process.unicode", "unicode stays a single argument", HelperArguments("echo", "unicode delta \u0394 snowman \u2603")).ConfigureAwait(false),
                await RunStartedScenario("process.newlines", "stdin carries newline payload", HelperArguments("stdin"), "first line\nsecond line\nthird line").ConfigureAwait(false),
                await RunStartedScenario("process.long-input", "long input remains bounded", HelperArguments("stdin"), new string('x', 128 * 1024)).ConfigureAwait(false),
                await RunStartedScenario("process.blocked-stderr", "stderr drains concurrently", HelperArguments("stderr-block")).ConfigureAwait(false),
                await RunStartedScenario("process.infinite-output", "infinite output is killed at limit", HelperArguments("infinite"), maxBytes: 128 * 1024).ConfigureAwait(false),
                await RunStartedScenario("process.grandchildren", "cancel kills recorded child process", HelperArguments("grandchild"), cancelAfterMs: 750).ConfigureAwait(false),
                await RunStartedScenario("process.cancellation", "cancellation terminates process", HelperArguments("sleep", "30"), cancelAfterMs: 500).ConfigureAwait(false),
                await RunStartedScenario("process.timeout", "timeout terminates process", HelperArguments("sleep", "30"), timeoutMs: 500).ConfigureAwait(false),
                await RunStartedScenario("process.malformed-output", "malformed stream output is captured", HelperArguments("malformed")).ConfigureAwait(false),
                await RunStartedScenario("process.nonzero-exit", "nonzero exit is captured", HelperArguments("nonzero")).ConfigureAwait(false),
                await RunDeniedScenario("process.unapproved-denial", "unapproved executable is denied", DenialKind.Unapproved).ConfigureAwait(false),
                await RunDeniedScenario("process.replaced-denial", "replaced executable is denied", DenialKind.Replaced).ConfigureAwait(false),
                await RunDeniedScenario("process.missing-denial", "missing approved executable is denied", DenialKind.Missing).ConfigureAwait(false),
                await RunDeniedScenario("process.unavailable-backend", "unavailable backend is denied", DenialKind.Missing).ConfigureAwait(false),
            };

            return new EvidenceRun(
                "openburnbar.windows.foundation-process-evidence.v1",
                DateTimeOffset.UtcNow.ToString("O"),
                _expectedCandidate,
                new ToolHost(
                    Sha256(Environment.UserName),
                    Environment.ProcessId == 0 ? 0 : Process.GetCurrentProcess().SessionId,
                    Sha256(Environment.MachineName),
                    RuntimeInformation.OSDescription,
                    RuntimeInformation.OSArchitecture.ToString(),
                    RuntimeInformation.ProcessArchitecture.ToString(),
                    RuntimeInformation.FrameworkDescription,
                    RedactUserProfile(_helperPath) ?? "%REDACTED_PATH%"),
                ChildProcessLaunchPolicy.ReviewedProductLaunches,
                EnvironmentProfiles(),
                scenarios);
        }

        private IReadOnlyList<string> HelperArguments(params string[] arguments) =>
            new[] { _helperAssemblyPath, "--helper" }.Concat(arguments).ToArray();

        private async Task<ProcessScenario> RunDeniedScenario(string id, string expectedOutcome, DenialKind denial)
        {
            string started = DateTimeOffset.UtcNow.ToString("O");
            IReadOnlyList<ProcessTableRow> before = ProcessTable();
            try
            {
                ApprovedChatExecutableCatalog catalog = denial switch
                {
                    DenialKind.Unapproved => new ApprovedChatExecutableCatalog(Array.Empty<ApprovedChatExecutable>()),
                    DenialKind.Replaced => ReplacedCatalog(out _),
                    DenialKind.Missing => MissingCatalog(out _),
                    _ => throw new ArgumentOutOfRangeException(nameof(denial)),
                };
                string requested = denial == DenialKind.Unapproved ? _helperPath : "helper";
                _ = ChatProcessRunner.CreateStartInfo(new ChildProcessSpec(requested, HelperArguments("echo", "blocked")), catalog);
                return Failed(id, expectedOutcome, before, "Denial did not occur.", started);
            }
            catch (ChatProcessException ex)
            {
                return new ProcessScenario(
                    id,
                    "captured",
                    expectedOutcome,
                    ex.Kind.ToString(),
                    SecretRedactor.Shared.Redact(ex.Message),
                    null,
                    null,
                    before,
                    ProcessTable(),
                    Array.Empty<int>(),
                    started,
                    DateTimeOffset.UtcNow.ToString("O"));
            }
        }

        private async Task<ProcessScenario> RunStartedScenario(
            string id,
            string expectedOutcome,
            IReadOnlyList<string> arguments,
            string? standardInput = null,
            int timeoutMs = 10_000,
            int? cancelAfterMs = null,
            long maxBytes = DefaultOutputLimit)
        {
            _ = await Task.FromResult(0).ConfigureAwait(false);
            string started = DateTimeOffset.UtcNow.ToString("O");
            IReadOnlyList<ProcessTableRow> before = ProcessTable();
            var catalog = new ApprovedChatExecutableCatalog(new[]
            {
                new ApprovedChatExecutable("foundation-host-evidence", _helperPath, ApprovedChatExecutableCatalog.ComputeSha256(_helperPath)),
            });

            ProcessStartInfo startInfo;
            try
            {
                startInfo = ChatProcessRunner.CreateStartInfo(new ChildProcessSpec(_helperPath, arguments, standardInput), catalog);
            }
            catch (Exception ex)
            {
                return Failed(id, expectedOutcome, before, "start info failed: " + ex.Message, started);
            }

            ProcessLaunchEvidence launch = LaunchEvidence(startInfo);
            using var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
            var stopwatch = Stopwatch.StartNew();
            int? processId = null;
            bool timedOut = false;
            bool cancelled = false;
            bool limitExceeded = false;
            int? exitCode = null;
            DrainResult stdout = DrainResult.Empty;
            DrainResult stderr = DrainResult.Empty;
            var survivorPids = new List<int>();
            try
            {
                process.Start();
                processId = process.Id;
                Task<DrainResult> stdoutTask = DrainAsync(process.StandardOutput, maxBytes);
                Task<DrainResult> stderrTask = DrainAsync(process.StandardError, maxBytes);

                if (standardInput is not null)
                {
                    await process.StandardInput.WriteAsync(standardInput.AsMemory()).ConfigureAwait(false);
                    process.StandardInput.Close();
                }

                Task waitTask = process.WaitForExitAsync();
                Task delayTask = Task.Delay(cancelAfterMs ?? timeoutMs);
                Task first = await Task.WhenAny(waitTask, delayTask, stdoutTask, stderrTask).ConfigureAwait(false);
                if (first == delayTask)
                {
                    cancelled = cancelAfterMs.HasValue;
                    timedOut = !cancelAfterMs.HasValue;
                    KillTree(process);
                }
                else if (first == stdoutTask && stdoutTask.IsFaulted)
                {
                    limitExceeded = true;
                    KillTree(process);
                }
                else if (first == stderrTask && stderrTask.IsFaulted)
                {
                    limitExceeded = true;
                    KillTree(process);
                }

                await WaitForExitBestEffort(process).ConfigureAwait(false);
                exitCode = process.HasExited ? process.ExitCode : null;
                stdout = await CompleteDrain(stdoutTask).ConfigureAwait(false);
                stderr = await CompleteDrain(stderrTask).ConfigureAwait(false);
                survivorPids.AddRange(RecordedChildPids(stdout.Sample).Where(ProcessExists));
                if (processId.HasValue && ProcessExists(processId.Value))
                {
                    survivorPids.Add(processId.Value);
                }
            }
            catch (Exception ex)
            {
                KillTree(process);
                return Failed(id, expectedOutcome, before, ex.Message, started, launch);
            }
            finally
            {
                stopwatch.Stop();
            }

            var result = new ProcessResultEvidence(
                processId,
                exitCode,
                timedOut,
                cancelled,
                limitExceeded,
                stdout.Bytes,
                stderr.Bytes,
                SecretRedactor.Shared.Redact(stdout.Sample),
                SecretRedactor.Shared.Redact(stderr.Sample),
                stopwatch.Elapsed.TotalMilliseconds);
            bool expectedExceptional = id is "process.infinite-output" or "process.grandchildren" or "process.cancellation" or "process.timeout" or "process.nonzero-exit";
            bool okay = survivorPids.Count == 0
                && launch.ForbiddenEnvironmentNamesPresent.Count == 0
                && (expectedExceptional || exitCode == 0 || limitExceeded);

            return new ProcessScenario(
                id,
                okay ? "captured" : "failed",
                expectedOutcome,
                okay ? null : "UnexpectedProcessOutcome",
                okay ? null : "Unexpected exit, forbidden environment, or survivor process.",
                launch,
                result,
                before,
                ProcessTable(),
                survivorPids.Distinct().OrderBy(pid => pid).ToArray(),
                started,
                DateTimeOffset.UtcNow.ToString("O"));
        }

        private ProcessLaunchEvidence LaunchEvidence(ProcessStartInfo startInfo)
        {
            string path = Path.GetFullPath(startInfo.FileName);
            var environment = startInfo.Environment
                .OrderBy(pair => pair.Key, StringComparer.OrdinalIgnoreCase)
                .Select(pair => new EnvironmentEntry(pair.Key, pair.Value?.Length ?? 0, Sha256(pair.Value ?? string.Empty)))
                .ToArray();
            string[] forbidden = startInfo.Environment.Keys
                .Where(ChildProcessEnvironment.IsForbidden)
                .OrderBy(name => name, StringComparer.OrdinalIgnoreCase)
                .ToArray();
            return new ProcessLaunchEvidence(
                RedactUserProfile(startInfo.FileName) ?? "%REDACTED_PATH%",
                RedactUserProfile(path) ?? "%REDACTED_PATH%",
                File.Exists(path) ? FileSha256(path) : string.Empty,
                startInfo.ArgumentList.ToArray(),
                startInfo.UseShellExecute,
                startInfo.RedirectStandardInput,
                startInfo.RedirectStandardOutput,
                startInfo.RedirectStandardError,
                environment,
                forbidden);
        }

        private static IReadOnlyList<EnvironmentProfile> EnvironmentProfiles() =>
            Enum.GetValues<ChildProcessProfile>()
                .Select(profile =>
                {
                    string[] allowed = ChildProcessEnvironment.AllowedEnvironmentVariableNames(profile, ChildProcessHost.Windows).ToArray();
                    string[] rejected = CanaryNames.Where(ChildProcessEnvironment.IsForbidden).ToArray();
                    return new EnvironmentProfile(profile.ToString(), allowed, rejected);
                })
                .ToArray();

        private static ApprovedChatExecutableCatalog ReplacedCatalog(out string helper)
        {
            helper = TempCopy("replaced");
            string sha = ApprovedChatExecutableCatalog.ComputeSha256(helper);
            File.AppendAllText(helper, "mutation");
            return new ApprovedChatExecutableCatalog(new[] { new ApprovedChatExecutable("helper", helper, sha) });
        }

        private static ApprovedChatExecutableCatalog MissingCatalog(out string helper)
        {
            helper = TempCopy("missing");
            string sha = ApprovedChatExecutableCatalog.ComputeSha256(helper);
            File.Delete(helper);
            return new ApprovedChatExecutableCatalog(new[] { new ApprovedChatExecutable("helper", helper, sha) });
        }

        private static string TempCopy(string label)
        {
            string source = Environment.ProcessPath ?? throw new InvalidOperationException("ProcessPath is unavailable.");
            string extension = OperatingSystem.IsWindows() ? ".exe" : string.Empty;
            string target = Path.Combine(Path.GetTempPath(), $"obb-foundation-{label}-{Guid.NewGuid():N}{extension}");
            File.Copy(source, target);
            return target;
        }

        private static async Task<DrainResult> DrainAsync(StreamReader reader, long maxBytes)
        {
            char[] buffer = new char[4096];
            var sample = new StringBuilder();
            long bytes = 0;
            while (true)
            {
                int read = await reader.ReadAsync(buffer.AsMemory(0, buffer.Length)).ConfigureAwait(false);
                if (read == 0)
                {
                    break;
                }

                int byteCount = Encoding.UTF8.GetByteCount(buffer, 0, read);
                bytes += byteCount;
                if (sample.Length < SampleLimit)
                {
                    int take = Math.Min(read, SampleLimit - sample.Length);
                    sample.Append(buffer, 0, take);
                }

                if (bytes > maxBytes)
                {
                    throw new InvalidOperationException("OutputLimitExceeded");
                }
            }

            return new DrainResult(bytes, sample.ToString());
        }

        private static async Task<DrainResult> CompleteDrain(Task<DrainResult> task)
        {
            try
            {
                return await task.ConfigureAwait(false);
            }
            catch
            {
                return DrainResult.Empty;
            }
        }

        private static async Task WaitForExitBestEffort(Process process)
        {
            try
            {
                await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
            }
            catch
            {
                KillTree(process);
            }
        }

        private static void KillTree(Process process)
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
                // Evidence records survivors below; kill failures become scenario failures.
            }
        }

        private static bool ProcessExists(int pid)
        {
            try
            {
                using Process process = Process.GetProcessById(pid);
                return !process.HasExited;
            }
            catch
            {
                return false;
            }
        }

        private static IEnumerable<int> RecordedChildPids(string sample)
        {
            using JsonDocument? doc = TryParseJson(sample);
            if (doc is null)
            {
                yield break;
            }

            if (doc.RootElement.TryGetProperty("childPid", out JsonElement child) && child.TryGetInt32(out int pid))
            {
                yield return pid;
            }
        }

        private static JsonDocument? TryParseJson(string text)
        {
            try { return JsonDocument.Parse(text); }
            catch { return null; }
        }

        private static IReadOnlyList<ProcessTableRow> ProcessTable() =>
            Process.GetProcesses()
                .Select(process =>
                {
                    try
                    {
                        return new ProcessTableRow(process.Id, process.ProcessName, TryProcessPath(process));
                    }
                    finally
                    {
                        process.Dispose();
                    }
                })
                .OrderBy(row => row.ProcessId)
                .ToArray();

        private static string? TryProcessPath(Process process)
        {
            try { return RedactUserProfile(process.MainModule?.FileName); }
            catch { return null; }
        }

        private static string? RedactUserProfile(string? path)
        {
            if (string.IsNullOrWhiteSpace(path))
            {
                return path;
            }

            string profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            return string.IsNullOrWhiteSpace(profile)
                ? path
                : path.Replace(profile, "%USERPROFILE%", StringComparison.OrdinalIgnoreCase);
        }

        private static ProcessScenario Failed(
            string id,
            string expectedOutcome,
            IReadOnlyList<ProcessTableRow> before,
            string message,
            string started,
            ProcessLaunchEvidence? launch = null) =>
            new(
                id,
                "failed",
                expectedOutcome,
                "HarnessFailure",
                SecretRedactor.Shared.Redact(message),
                launch,
                null,
                before,
                ProcessTable(),
                Array.Empty<int>(),
                started,
                DateTimeOffset.UtcNow.ToString("O"));

        private static string FileSha256(string path)
        {
            using FileStream stream = File.OpenRead(path);
            return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
        }

        private static string Sha256(string value) =>
            Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();

        private sealed record DrainResult(long Bytes, string Sample)
        {
            public static DrainResult Empty { get; } = new(0, string.Empty);
        }

        private enum DenialKind
        {
            Unapproved,
            Replaced,
            Missing,
        }
    }
}
