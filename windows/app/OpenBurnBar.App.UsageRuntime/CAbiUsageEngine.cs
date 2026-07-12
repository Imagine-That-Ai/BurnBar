using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.UsageRuntime;

/// <summary>
/// Loads the shared Swift parser engine in-process and invokes its structured
/// usage-scan export. No shell or child process participates in ingestion.
/// </summary>
public sealed class CAbiUsageEngine : IUsageEngine, IDisposable
{
    private const string WindowsLibraryName = "OpenBurnBarCoreCAbi.dll";
    private const string MacLibraryName = "libOpenBurnBarCoreCAbi.dylib";
    private static readonly object LibraryCacheGate = new();
    private static readonly Dictionary<string, NativeBindings> LibraryCache =
        new(OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);

    private readonly object _gate = new();
    private readonly Func<string?> _libraryPathResolver;
    private readonly JsonSerializerOptions _jsonOptions = new()
    {
        PropertyNameCaseInsensitive = false,
        Converters = { new JsonStringEnumConverter() },
    };

    private IntPtr _libraryHandle;
    private ScanUsageDelegate? _scanUsage;
    private StringFreeDelegate? _stringFree;
    private bool _disposed;

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate IntPtr ScanUsageDelegate(IntPtr requestJson);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void StringFreeDelegate(IntPtr value);

    private sealed record NativeBindings(
        IntPtr Handle,
        ScanUsageDelegate ScanUsage,
        StringFreeDelegate StringFree);

    public CAbiUsageEngine(Func<string?>? libraryPathResolver = null)
    {
        _libraryPathResolver = libraryPathResolver ?? ResolveLibraryPath;
    }

    public ValueTask<UsageEngineScanResponse> ScanAsync(
        UsageEngineScanRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        ObjectDisposedException.ThrowIf(_disposed, this);
        cancellationToken.ThrowIfCancellationRequested();

        return new ValueTask<UsageEngineScanResponse>(Task.Run(
            () => Scan(request, cancellationToken),
            cancellationToken));
    }

    private UsageEngineScanResponse Scan(
        UsageEngineScanRequest request,
        CancellationToken cancellationToken)
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            cancellationToken.ThrowIfCancellationRequested();
            EnsureLoaded();

            string requestJson = JsonSerializer.Serialize(request, _jsonOptions);
            IntPtr requestPointer = Marshal.StringToCoTaskMemUTF8(requestJson);
            IntPtr responsePointer = IntPtr.Zero;
            try
            {
                responsePointer = _scanUsage!(requestPointer);
                if (responsePointer == IntPtr.Zero)
                {
                    throw new UsageRuntimeException(
                        UsageRuntimeFailureKind.NativeEngineFailure,
                        "The parser engine returned no scan response.");
                }

                string? responseJson = Marshal.PtrToStringUTF8(responsePointer);
                if (string.IsNullOrWhiteSpace(responseJson))
                {
                    throw new UsageRuntimeException(
                        UsageRuntimeFailureKind.InvalidEngineResponse,
                        "The parser engine returned an empty scan response.");
                }

                UsageEngineScanResponse? response;
                try
                {
                    response = JsonSerializer.Deserialize<UsageEngineScanResponse>(responseJson, _jsonOptions);
                }
                catch (JsonException ex)
                {
                    throw new UsageRuntimeException(
                        UsageRuntimeFailureKind.InvalidEngineResponse,
                        "The parser engine returned an invalid scan response.",
                        ex);
                }

                cancellationToken.ThrowIfCancellationRequested();
                return response ?? throw new UsageRuntimeException(
                    UsageRuntimeFailureKind.InvalidEngineResponse,
                    "The parser engine returned a null scan response.");
            }
            finally
            {
                if (responsePointer != IntPtr.Zero)
                {
                    _stringFree!(responsePointer);
                }
                Marshal.FreeCoTaskMem(requestPointer);
            }
        }
    }

    private void EnsureLoaded()
    {
        if (_libraryHandle != IntPtr.Zero)
        {
            return;
        }

        string? path = _libraryPathResolver();
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
        {
            throw new UsageRuntimeException(
                UsageRuntimeFailureKind.NativeEngineUnavailable,
                "The OpenBurnBar parser engine is not installed. Repair or reinstall OpenBurnBar.");
        }

        path = Path.GetFullPath(path);
        lock (LibraryCacheGate)
        {
            if (LibraryCache.TryGetValue(path, out NativeBindings? cached))
            {
                _libraryHandle = cached.Handle;
                _scanUsage = cached.ScanUsage;
                _stringFree = cached.StringFree;
                return;
            }

            try
            {
                IntPtr handle = NativeLibrary.Load(path);
                _ = NativeLibrary.GetExport(handle, "obb_parse_cli_stdout");
                var scanUsage = Marshal.GetDelegateForFunctionPointer<ScanUsageDelegate>(
                    NativeLibrary.GetExport(handle, "obb_scan_usage"));
                var stringFree = Marshal.GetDelegateForFunctionPointer<StringFreeDelegate>(
                    NativeLibrary.GetExport(handle, "obb_string_free"));
                var bindings = new NativeBindings(handle, scanUsage, stringFree);
                LibraryCache.Add(path, bindings);
                _libraryHandle = bindings.Handle;
                _scanUsage = bindings.ScanUsage;
                _stringFree = bindings.StringFree;
            }
            catch (Exception ex) when (ex is DllNotFoundException
                                       or BadImageFormatException
                                       or EntryPointNotFoundException)
            {
                _libraryHandle = IntPtr.Zero;
                _scanUsage = null;
                _stringFree = null;
                throw new UsageRuntimeException(
                    UsageRuntimeFailureKind.NativeEngineUnavailable,
                    "The OpenBurnBar parser engine could not be loaded. Repair or reinstall OpenBurnBar.",
                    ex);
            }
        }
    }

    public static string? ResolveLibraryPath()
    {
        string? explicitPath = Environment.GetEnvironmentVariable("OPENBURNBAR_CORE_CABI_PATH");
        if (!string.IsNullOrWhiteSpace(explicitPath) && File.Exists(explicitPath))
        {
            return Path.GetFullPath(explicitPath);
        }

        string libraryName = OperatingSystem.IsWindows() ? WindowsLibraryName : MacLibraryName;
        var candidates = new List<string>
        {
            Path.Combine(AppContext.BaseDirectory, libraryName),
            Path.Combine(AppContext.BaseDirectory, "native", libraryName),
        };

        string? packagePath = Environment.GetEnvironmentVariable("OPENBURNBAR_CORE_PACKAGE_PATH");
        if (string.IsNullOrWhiteSpace(packagePath))
        {
            packagePath = FindPackagePath(AppContext.BaseDirectory);
        }

        if (!string.IsNullOrWhiteSpace(packagePath))
        {
            candidates.Add(Path.Combine(packagePath, ".build", "out", "Products", "Debug", libraryName));
            candidates.Add(Path.Combine(packagePath, ".build", "out", "Products", "Release", libraryName));
            candidates.Add(Path.Combine(packagePath, ".build", "debug", libraryName));
            candidates.Add(Path.Combine(packagePath, ".build", "release", libraryName));
            candidates.Add(Path.Combine(packagePath, ".build", "x86_64-unknown-windows-msvc", "release", libraryName));
            candidates.Add(Path.Combine(packagePath, ".build", "aarch64-unknown-windows-msvc", "release", libraryName));
            candidates.Add(Path.Combine(packagePath, ".build", "arm64-apple-macosx", "debug", libraryName));
        }

        foreach (string candidate in candidates)
        {
            if (File.Exists(candidate))
            {
                return Path.GetFullPath(candidate);
            }
        }

        return null;
    }

    private static string? FindPackagePath(string startDirectory)
    {
        string? directory = startDirectory;
        for (int depth = 0; depth < 12 && directory is not null; depth++)
        {
            string candidate = Path.Combine(directory, "OpenBurnBarCore");
            if (File.Exists(Path.Combine(candidate, "Package.swift")))
            {
                return candidate;
            }
            directory = Directory.GetParent(directory)?.FullName;
        }
        return null;
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }
            _disposed = true;
            _scanUsage = null;
            _stringFree = null;
            // Swift runtime globals and delegates are process-scoped. Unloading the
            // DLL deadlocks in its Windows shutdown path, so cached bindings live
            // until normal process teardown releases the module.
            _libraryHandle = IntPtr.Zero;
        }
    }
}
