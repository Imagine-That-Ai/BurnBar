using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.ExceptionServices;
using System.Threading.Tasks;
using System.Text;
using Microsoft.UI.Xaml;
using OpenBurnBar.App.Configuration;
namespace OpenBurnBar.App.Diagnostics;

/// <summary>
/// Best-effort process diagnostics for the unpackaged WinUI shell. The route-smoke harness and
/// crash triage both read these files from %LOCALAPPDATA%\OpenBurnBar\logs.
/// </summary>
public static class AppDiagnostics
{
    private static readonly object Gate = new();
    private static bool _installed;
    private static string? _activeRouteKey;

    public static string LogDirectory
    {
        get
        {
            return RuntimePaths.AppDataSubdirectory("logs");
        }
    }

    public static string CrashLogPath => Path.Combine(LogDirectory, "winui-crash.log");

    public static string RouteLogPath => Path.Combine(LogDirectory, "route-breadcrumbs.log");

    public static string ActiveRouteKey
    {
        get
        {
            lock (Gate)
            {
                return _activeRouteKey ?? string.Empty;
            }
        }
    }

    public static void Install(Application app)
    {
        if (_installed)
        {
            return;
        }

        _installed = true;
        Directory.CreateDirectory(LogDirectory);
        LogEvent("process", "diagnostics-installed");

        app.UnhandledException += (_, args) =>
        {
            LogException("Application.UnhandledException", args.Exception);
        };

        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            LogException("AppDomain.UnhandledException", args.ExceptionObject as Exception);
        };

        AppDomain.CurrentDomain.FirstChanceException += (_, args) =>
        {
            if (IsNativeRouteException(args.Exception))
            {
                LogException("FirstChance.NativeRoute", args.Exception);
            }
        };

        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            LogException("TaskScheduler.UnobservedTaskException", args.Exception);
            args.SetObserved();
        };
    }

    public static void LogEvent(string category, string message) => Append(CrashLogPath, Format(category, message));

    public static void LogException(string category, Exception? exception) =>
        Append(CrashLogPath, Format(category, Describe(exception)));

    public static void RouteBegin(string key, Type pageType)
    {
        lock (Gate)
        {
            _activeRouteKey = key;
        }

        Append(RouteLogPath, Format("route.begin", $"{key} -> {pageType.FullName}"));
    }

    public static void RouteSuccess(string key, Type pageType) =>
        Append(RouteLogPath, Format("route.success", $"{key} -> {pageType.FullName}"));

    public static void RouteFailure(string key, Type pageType, Exception exception)
    {
        Append(RouteLogPath, Format("route.failure", $"{key} -> {pageType.FullName}\n{Describe(exception)}"));
        LogException($"route.failure:{key}", exception);
    }

    public static void NativeCapabilitySkipped(string feature, string reason) =>
        LogEvent("native.skipped", $"{feature}: {reason}");

    private static string Format(string category, string message)
    {
        string route = ActiveRouteKey;
        string routeSuffix = string.IsNullOrEmpty(route) ? string.Empty : $" route={route}";
        return $"[{DateTimeOffset.UtcNow:O}] {category}{routeSuffix} pid={Environment.ProcessId}{Environment.NewLine}{message}{Environment.NewLine}";
    }

    private static string Describe(Exception? exception)
    {
        if (exception is null)
        {
            return "<non-Exception object>";
        }

        var builder = new StringBuilder();
        Exception current = exception;
        var depth = 0;
        while (current is not null && depth < 8)
        {
            builder.Append(current.GetType().FullName)
                .Append(" hresult=0x")
                .Append(current.HResult.ToString("X8"))
                .Append(' ')
                .AppendLine(current.Message)
                .AppendLine(current.StackTrace);
            current = current.InnerException!;
            depth++;
        }

        return builder.ToString();
    }

    private static bool IsNativeRouteException(Exception exception)
    {
        string type = exception.GetType().FullName ?? string.Empty;
        string message = exception.Message ?? string.Empty;
        return exception.HResult == unchecked((int)0x80004002)
            || exception.HResult == unchecked((int)0x80040154)
            || exception.HResult == unchecked((int)0x8007007E)
            || type.Contains("COMException", StringComparison.Ordinal)
            || message.Contains("Microsoft.UI.Xaml", StringComparison.OrdinalIgnoreCase)
            || message.Contains("WebView2", StringComparison.OrdinalIgnoreCase)
            || message.Contains("Win2D", StringComparison.OrdinalIgnoreCase);
    }

    private static void Append(string path, string text)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.AppendAllText(path, text, Encoding.UTF8);
            Debug.WriteLine(text);
        }
        catch
        {
            // Diagnostics are best effort and must never crash the app.
        }
    }
}
