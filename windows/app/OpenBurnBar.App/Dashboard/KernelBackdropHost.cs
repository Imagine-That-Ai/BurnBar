using System;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Diagnostics;

namespace OpenBurnBar.App.Dashboard;

/// <summary>
/// Native Windows host for the shared kernel picker. Each persisted macOS
/// kernel id maps to a ported Win2D substrate, preserving the live animated
/// backdrop without WebView2 HWND airspace over dashboard XAML.
/// </summary>
public sealed class KernelBackdropHost : IDisposable
{
    private readonly DashboardBackdrop _backdrop = new();
    private bool _started;
    private bool _disposed;
    private bool _isReady;
    private bool _isFailed;
    private string? _failureReason;

    public Image Control => _backdrop.Control;

    public bool IsReady => _isReady;

    public bool IsFailed => _isFailed;

    public string? FailureReason => _failureReason;

    public event EventHandler? Ready;

    public event EventHandler<string>? Failed;

    public Task StartAsync(string? kernelId = null, string theme = "dark")
    {
        if (_disposed || _started || _isFailed)
        {
            return Task.CompletedTask;
        }

        _started = true;
        try
        {
            _backdrop.SetTheme(theme);
            _backdrop.SetKernel(kernelId);
            _isReady = true;
            Ready?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception ex)
        {
            AppDiagnostics.LogException("kernel-backdrop.native", ex);
            Fail("native-init-exception:" + ex.GetType().Name);
        }

        return Task.CompletedTask;
    }

    public void SetKernel(string? kernelId)
    {
        if (!_disposed && !_isFailed)
        {
            _backdrop.SetKernel(kernelId);
        }
    }

    public void SetTheme(string theme)
    {
        if (!_disposed && !_isFailed)
        {
            _backdrop.SetTheme(theme);
        }
    }

    public void SetBackdropActive(bool active)
    {
        if (_disposed || _isFailed)
        {
            return;
        }

        _backdrop.Paused = !active;
        Control.Visibility = active ? Visibility.Visible : Visibility.Collapsed;
    }

    private void Fail(string reason)
    {
        if (_isFailed || _disposed)
        {
            return;
        }

        _isFailed = true;
        _failureReason = reason;
        Failed?.Invoke(this, reason);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _backdrop.Dispose();
    }
}
