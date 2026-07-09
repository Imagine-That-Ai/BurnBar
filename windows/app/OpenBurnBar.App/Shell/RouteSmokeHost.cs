using System;
using System.IO;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using OpenBurnBar.App.Diagnostics;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace OpenBurnBar.App.Shell;

internal static class RouteSmokeHost
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    public static async Task CaptureAndExitAsync(MainWindow window, RouteSmokeOptions options)
    {
        Directory.CreateDirectory(options.OutputDirectory);
        AppDiagnostics.LogEvent("route-smoke.capture.begin", options.RouteKey);
        var started = DateTimeOffset.UtcNow;
        RouteSmokeResult result;
        try
        {
            await WaitForRenderAsync(options.TimeoutMilliseconds).ConfigureAwait(true);
            AppDiagnostics.LogEvent("route-smoke.capture.after-render-wait", options.RouteKey);
            FrameworkElement root = window.Content as FrameworkElement
                ?? throw new InvalidOperationException("MainWindow.Content is not a FrameworkElement.");

            string screenshotPath = Path.Combine(options.OutputDirectory, $"{SafeName(options.RouteKey)}.png");
            PixelStats stats = await CapturePngAsync(root, screenshotPath).ConfigureAwait(true);
            AppDiagnostics.LogEvent("route-smoke.capture.after-png", $"{options.RouteKey} -> {screenshotPath}");
            string expectedAutomationId = ExpectedAutomationId(options.RouteKey);
            bool expectedAutomationIdFound = ContainsAutomationId(root, expectedAutomationId);
            result = RouteSmokeResult.Pass(
                options.RouteKey,
                screenshotPath,
                stats,
                DateTimeOffset.UtcNow - started,
                root.ActualWidth,
                root.ActualHeight,
                root.ActualTheme.ToString(),
                expectedAutomationId,
                expectedAutomationIdFound);
        }
        catch (Exception ex)
        {
            AppDiagnostics.LogException("route-smoke.failure", ex);
            result = RouteSmokeResult.Fail(
                options.RouteKey,
                DateTimeOffset.UtcNow - started,
                ex);
        }

        await WriteResultAsync(options.OutputDirectory, result).ConfigureAwait(false);
        AppDiagnostics.LogEvent("route-smoke.capture.exit", $"{options.RouteKey} code={result.ExitCode}");
        Environment.Exit(result.ExitCode);
    }

    private static async Task WaitForRenderAsync(int timeoutMilliseconds)
    {
        int delay = Math.Clamp(timeoutMilliseconds / 8, 250, 1000);
        await Task.Delay(delay).ConfigureAwait(true);
        await DispatcherQueue.GetForCurrentThread().EnqueueAsync(() => { }).ConfigureAwait(true);
    }

    private static async Task<PixelStats> CapturePngAsync(FrameworkElement root, string screenshotPath)
    {
        var bitmap = new RenderTargetBitmap();
        await bitmap.RenderAsync(root).AsTask().ConfigureAwait(true);
        Windows.Storage.Streams.IBuffer pixels = await bitmap.GetPixelsAsync().AsTask().ConfigureAwait(true);
        byte[] bytes = pixels.ToArray();
        PixelStats stats = PixelStats.FromBgra(bytes, bitmap.PixelWidth, bitmap.PixelHeight);

        await using FileStream stream = File.Create(screenshotPath);
        using IRandomAccessStream random = stream.AsRandomAccessStream();
        BitmapEncoder encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, random).AsTask().ConfigureAwait(true);
        encoder.SetPixelData(
            BitmapPixelFormat.Bgra8,
            BitmapAlphaMode.Premultiplied,
            (uint)bitmap.PixelWidth,
            (uint)bitmap.PixelHeight,
            96,
            96,
            bytes);
        await encoder.FlushAsync().AsTask().ConfigureAwait(true);
        return stats;
    }

    private static async Task WriteResultAsync(string outputDirectory, RouteSmokeResult result)
    {
        string resultPath = Path.Combine(outputDirectory, $"{SafeName(result.RouteKey)}-result.json");
        string json = JsonSerializer.Serialize(result, JsonOptions);
        await File.WriteAllTextAsync(resultPath, json).ConfigureAwait(false);
        await File.AppendAllTextAsync(
            Path.Combine(outputDirectory, "route-smoke-log.txt"),
            $"[{DateTimeOffset.UtcNow:O}] {result.RouteKey} exit={result.ExitCode} nearUniform={result.NearUniform} error={result.ExceptionType} {result.Message}{Environment.NewLine}").ConfigureAwait(false);
    }

    private static string SafeName(string routeKey)
    {
        foreach (char invalid in Path.GetInvalidFileNameChars())
        {
            routeKey = routeKey.Replace(invalid, '-');
        }

        return routeKey;
    }

    private static bool ContainsAutomationId(DependencyObject root, string expectedAutomationId)
    {
        if (string.Equals(AutomationProperties.GetAutomationId(root), expectedAutomationId, StringComparison.Ordinal))
        {
            return true;
        }

        int childCount = VisualTreeHelper.GetChildrenCount(root);
        for (var i = 0; i < childCount; i++)
        {
            if (ContainsAutomationId(VisualTreeHelper.GetChild(root, i), expectedAutomationId))
            {
                return true;
            }
        }

        return false;
    }

    private sealed record PixelStats(int Width, int Height, double MeanLuma, double LumaStdDev, bool NearUniform)
    {
        public static PixelStats FromBgra(byte[] bgra, int width, int height)
        {
            if (width <= 0 || height <= 0 || bgra.Length < 4)
            {
                return new PixelStats(width, height, 0, 0, NearUniform: true);
            }

            double sum = 0;
            double sumSq = 0;
            int pixels = Math.Min(width * height, bgra.Length / 4);
            for (var i = 0; i < pixels; i++)
            {
                int offset = i * 4;
                double b = bgra[offset];
                double g = bgra[offset + 1];
                double r = bgra[offset + 2];
                double luma = (0.2126 * r) + (0.7152 * g) + (0.0722 * b);
                sum += luma;
                sumSq += luma * luma;
            }

            double mean = sum / pixels;
            double variance = Math.Max(0, (sumSq / pixels) - (mean * mean));
            double stdDev = Math.Sqrt(variance);
            bool nearUniform = pixels < 10_000 || stdDev < 3.0 || (mean > 240 && stdDev < 12.0);
            return new PixelStats(width, height, mean, stdDev, nearUniform);
        }
    }

    private sealed record RouteSmokeResult(
        string RouteKey,
        int ExitCode,
        string? ScreenshotPath,
        int Width,
        int Height,
        double MeanLuma,
        double LumaStdDev,
        bool NearUniform,
        double ElapsedMs,
        double ActualWidth,
        double ActualHeight,
        string? Theme,
        string ExpectedAutomationId,
        bool ExpectedAutomationIdFound,
        string? ExceptionType,
        string? Message)
    {
        public static RouteSmokeResult Pass(
            string routeKey,
            string screenshotPath,
            PixelStats stats,
            TimeSpan elapsed,
            double actualWidth,
            double actualHeight,
            string theme,
            string expectedAutomationId,
            bool expectedAutomationIdFound) =>
            new(
                routeKey,
                stats.NearUniform || !expectedAutomationIdFound ? 2 : 0,
                screenshotPath,
                stats.Width,
                stats.Height,
                stats.MeanLuma,
                stats.LumaStdDev,
                stats.NearUniform,
                elapsed.TotalMilliseconds,
                actualWidth,
                actualHeight,
                theme,
                expectedAutomationId,
                expectedAutomationIdFound,
                null,
                stats.NearUniform
                    ? "Screenshot is near-uniform/blank."
                    : expectedAutomationIdFound
                        ? null
                        : $"Expected automation id was not found: {expectedAutomationId}");

        public static RouteSmokeResult Fail(string routeKey, TimeSpan elapsed, Exception exception) =>
            new(
                routeKey,
                1,
                null,
                0,
                0,
                0,
                0,
                NearUniform: true,
                elapsed.TotalMilliseconds,
                0,
                0,
                null,
                RouteSmokeHost.ExpectedAutomationId(routeKey),
                ExpectedAutomationIdFound: false,
                exception.GetType().FullName,
                exception.Message);
    }

    private static string ExpectedAutomationId(string routeKey) => $"RouteRoot.{routeKey}";
}

internal static class DispatcherQueueExtensions
{
    public static Task EnqueueAsync(this DispatcherQueue queue, Action action)
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!queue.TryEnqueue(() =>
            {
                try
                {
                    action();
                    completion.SetResult();
                }
                catch (Exception ex)
                {
                    completion.SetException(ex);
                }
            }))
        {
            completion.SetException(new InvalidOperationException("DispatcherQueue rejected route-smoke continuation."));
        }

        return completion.Task;
    }
}
