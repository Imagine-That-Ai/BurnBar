using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using OpenBurnBar.Integrations.Mercury.Adapters;
using OpenBurnBar.Integrations.Mercury.Windows;

namespace OpenBurnBar.Mercury.Capture.HostHarness;

internal static class Program
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
    private static int _exitCode = 2;

    [STAThread]
    private static int Main(string[] args)
    {
        string output = ParseOutput(args);
        Directory.CreateDirectory(output);
        int roInitialize = RoInitialize(0);
        bool shouldUninitialize = roInitialize is 0 or 1;
        if (roInitialize < 0 && roInitialize != unchecked((int)0x80010106))
        {
            Marshal.ThrowExceptionForHR(roInitialize);
        }

        try
        {
            ApplicationConfiguration.Initialize();
            using var form = new CaptureProbeForm();
            form.Shown += async (_, _) =>
            {
                try
                {
                    CaptureHostSummary summary = await RunAsync(form, output);
                    WriteSummary(output, summary);
                    _exitCode = summary.Passed ? 0 : 1;
                }
                catch (Exception ex)
                {
                    File.WriteAllText(
                        Path.Combine(output, "mercury-capture-host-summary.json"),
                        JsonSerializer.Serialize(new
                        {
                            passed = false,
                            generatedAtUtc = DateTimeOffset.UtcNow,
                            errorType = ex.GetType().FullName,
                            error = ex.Message,
                            stack = ex.StackTrace,
                        }, JsonOptions));
                    _exitCode = 1;
                }
                finally
                {
                    form.Close();
                }
            };
            Application.Run(form);
            return _exitCode;
        }
        finally
        {
            if (shouldUninitialize)
            {
                RoUninitialize();
            }
        }
    }

    private static async Task<CaptureHostSummary> RunAsync(CaptureProbeForm form, string output)
    {
        form.Activate();
        SetForegroundWindow(form.Handle);
        await Task.Delay(500).ConfigureAwait(true);

        var checks = new List<CaptureHostCheck>();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        await using var source = GraphicsCaptureScreenSource.CreateForWindow(form.Handle);
        var completion = new TaskCompletionSource<CapturedFrame>(TaskCreationOptions.RunContinuationsAsynchronously);

        await source.StartAsync(
            new ScreenCaptureConfiguration { WindowHandle = form.Handle.ToInt64(), CaptureCursor = false },
            frame =>
            {
                completion.TrySetResult(frame);
                return ValueTask.CompletedTask;
            },
            timeout.Token).ConfigureAwait(true);

        CapturedFrame capture = await completion.Task.WaitAsync(timeout.Token).ConfigureAwait(true);
        await source.StopAsync().ConfigureAwait(true);

        int expectedBytes = checked(capture.Width * capture.Height * 4);
        Add(checks, "wgc-positive-dimensions", capture.Width > 0 && capture.Height > 0,
            $"width={capture.Width}; height={capture.Height}");
        Add(checks, "wgc-bgra-length", capture.Data.Length == expectedBytes,
            $"bytes={capture.Data.Length}; expected={expectedBytes}");

        FrameStatistics statistics = Measure(capture.Data);
        Add(checks, "wgc-nonblank-pixels", statistics.DistinctSampledColors >= 8 && statistics.LumaRange >= 32,
            $"distinct={statistics.DistinctSampledColors}; lumaRange={statistics.LumaRange}; nonZeroRgb={statistics.NonZeroRgbSamples}");
        Add(checks, "wgc-no-adapter-error", source.LastError is null,
            source.LastError?.GetType().Name ?? "none");

        string capturePath = Path.Combine(output, "mercury-capture-wgc.png");
        SaveBgraPng(capture, capturePath);
        Add(checks, "wgc-png-written", new FileInfo(capturePath).Length > 1024,
            $"bytes={new FileInfo(capturePath).Length}");

        bool encoderDenied = false;
        try
        {
            await using var encoder = new MediaFoundationVideoEncoder();
            await encoder.StartAsync(
                new VideoEncoderConfiguration
                {
                    Width = capture.Width,
                    Height = capture.Height,
                    FrameRate = 30,
                    TargetBitsPerSecond = 2_000_000,
                    PreferredCodec = "h264",
                },
                _ => ValueTask.CompletedTask,
                timeout.Token).ConfigureAwait(true);
        }
        catch (PlatformNotSupportedException)
        {
            encoderDenied = true;
        }

        Add(checks, "uncertified-encoder-fails-closed", encoderDenied,
            $"denied={encoderDenied}");

        return new CaptureHostSummary(
            Passed: checks.All(check => check.Passed),
            GeneratedAtUtc: DateTimeOffset.UtcNow,
            MachineName: Environment.MachineName,
            OsVersion: Environment.OSVersion.VersionString,
            OsArchitecture: RuntimeInformation.OSArchitecture.ToString(),
            ProcessArchitecture: RuntimeInformation.ProcessArchitecture.ToString(),
            Framework: RuntimeInformation.FrameworkDescription,
            CaptureWidth: capture.Width,
            CaptureHeight: capture.Height,
            CaptureBytes: capture.Data.LongLength,
            CaptureSha256: Sha256(capture.Data),
            CapturePngSha256: Sha256(File.ReadAllBytes(capturePath)),
            Checks: checks);
    }

    private static FrameStatistics Measure(byte[] bgra)
    {
        var colors = new HashSet<int>();
        int pixels = bgra.Length / 4;
        int step = Math.Max(1, pixels / 20_000);
        int minLuma = 255;
        int maxLuma = 0;
        int nonZero = 0;
        for (int pixel = 0; pixel < pixels; pixel += step)
        {
            int offset = pixel * 4;
            int blue = bgra[offset];
            int green = bgra[offset + 1];
            int red = bgra[offset + 2];
            int luma = ((red * 54) + (green * 183) + (blue * 19)) >> 8;
            minLuma = Math.Min(minLuma, luma);
            maxLuma = Math.Max(maxLuma, luma);
            if (red != 0 || green != 0 || blue != 0)
            {
                nonZero++;
            }

            if (colors.Count < 512)
            {
                colors.Add((red << 16) | (green << 8) | blue);
            }
        }

        return new FrameStatistics(colors.Count, maxLuma - minLuma, nonZero);
    }

    private static void SaveBgraPng(CapturedFrame frame, string path)
    {
        using var bitmap = new Bitmap(frame.Width, frame.Height, PixelFormat.Format32bppArgb);
        Rectangle bounds = new(0, 0, frame.Width, frame.Height);
        BitmapData data = bitmap.LockBits(bounds, ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        try
        {
            int sourceStride = checked(frame.Width * 4);
            for (int row = 0; row < frame.Height; row++)
            {
                Marshal.Copy(
                    frame.Data,
                    row * sourceStride,
                    IntPtr.Add(data.Scan0, row * data.Stride),
                    sourceStride);
            }
        }
        finally
        {
            bitmap.UnlockBits(data);
        }

        bitmap.Save(path, ImageFormat.Png);
    }

    private static void Add(ICollection<CaptureHostCheck> checks, string name, bool passed, string detail) =>
        checks.Add(new CaptureHostCheck(name, passed, detail));

    private static string ParseOutput(string[] args)
    {
        for (int index = 0; index < args.Length - 1; index++)
        {
            if (string.Equals(args[index], "--output", StringComparison.Ordinal))
            {
                return Path.GetFullPath(args[index + 1]);
            }
        }

        throw new ArgumentException("Usage: --output <directory>");
    }

    private static string Sha256(byte[] bytes) =>
        Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    private static void WriteSummary(string output, CaptureHostSummary summary) =>
        File.WriteAllText(
            Path.Combine(output, "mercury-capture-host-summary.json"),
            JsonSerializer.Serialize(summary, JsonOptions));

    [DllImport("combase.dll")]
    private static extern int RoInitialize(uint initializationType);

    [DllImport("combase.dll")]
    private static extern void RoUninitialize();

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr window);
}

internal sealed class CaptureProbeForm : Form
{
    public CaptureProbeForm()
    {
        Text = "OpenBurnBar Mercury Capture Certification";
        ClientSize = new Size(960, 600);
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        TopMost = true;
        BackColor = Color.FromArgb(245, 247, 250);

        var header = new Label
        {
            Text = "MERCURY / WINDOWS GRAPHICS CAPTURE",
            Font = new Font("Segoe UI", 20, FontStyle.Bold),
            ForeColor = Color.White,
            BackColor = Color.FromArgb(22, 27, 34),
            TextAlign = ContentAlignment.MiddleCenter,
        };
        header.SetBounds(24, 24, 912, 96);
        Controls.Add(header);

        Controls.Add(Panel(Color.FromArgb(0, 120, 212), 24, 148, 280, 260));
        Controls.Add(Panel(Color.FromArgb(22, 163, 74), 340, 148, 280, 260));
        Controls.Add(Panel(Color.FromArgb(220, 38, 38), 656, 148, 280, 260));

        var footer = new Label
        {
            Text = "NONBLANK BGRA PROBE  |  NO PRODUCTION DATA",
            Font = new Font("Consolas", 16, FontStyle.Bold),
            ForeColor = Color.FromArgb(22, 27, 34),
            BackColor = Color.FromArgb(255, 215, 0),
            TextAlign = ContentAlignment.MiddleCenter,
        };
        footer.SetBounds(24, 442, 912, 108);
        Controls.Add(footer);
    }

    private static Panel Panel(Color color, int x, int y, int width, int height) => new()
    {
        BackColor = color,
        Bounds = new Rectangle(x, y, width, height),
    };
}

internal sealed record CaptureHostCheck(string Name, bool Passed, string Detail);

internal sealed record FrameStatistics(int DistinctSampledColors, int LumaRange, int NonZeroRgbSamples);

internal sealed record CaptureHostSummary(
    bool Passed,
    DateTimeOffset GeneratedAtUtc,
    string MachineName,
    string OsVersion,
    string OsArchitecture,
    string ProcessArchitecture,
    string Framework,
    int CaptureWidth,
    int CaptureHeight,
    long CaptureBytes,
    string CaptureSha256,
    string CapturePngSha256,
    IReadOnlyList<CaptureHostCheck> Checks);
