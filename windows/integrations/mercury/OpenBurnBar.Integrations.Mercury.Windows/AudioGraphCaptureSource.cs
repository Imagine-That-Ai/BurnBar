using System;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Integrations.Mercury.Adapters;
using Windows.Media.Audio;
using Windows.Media.Capture;
using Windows.Media.MediaProperties;
using Windows.Media.Render;
using CapturedFrame = OpenBurnBar.Integrations.Mercury.Adapters.CapturedFrame;

namespace OpenBurnBar.Integrations.Mercury.Windows;

/// <summary>
/// WASAPI-backed microphone capture implementing <see cref="IAudioCaptureSource"/>
/// via <see cref="AudioGraph"/> (parity: the macOS MicrophoneCapturePipeline /
/// AVAudioEngine tap). An <see cref="AudioDeviceInputNode"/> feeds an
/// <see cref="AudioFrameOutputNode"/>; each quantum's PCM is drained and handed to
/// the portable pipeline as a <see cref="CapturedFrame"/>, with the mute flag
/// mirrored onto <see cref="MediaFrameFlags.Muted"/> upstream.
///
/// AudioGraph / MediaCapture are WinRT projections (type-checked on macOS) with no
/// macOS runtime; capture only runs on a Windows dev host / CI.
/// </summary>
public sealed class AudioGraphCaptureSource : IAudioCaptureSource
{
    private readonly SemaphoreSlim _frameGate = new(1, 1);
    private AudioGraph? _graph;
    private AudioDeviceInputNode? _inputNode;
    private AudioFrameOutputNode? _outputNode;
    private CancellationTokenSource? _captureCancellation;
    private Func<CapturedFrame, ValueTask>? _onFrame;
    private ulong _quantumCounter;
    private bool _disposed;

    public bool IsMuted { get; set; }

    public Exception? LastError { get; private set; }

    public async Task StartAsync(Func<CapturedFrame, ValueTask> onFrame, CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentNullException.ThrowIfNull(onFrame);
        cancellationToken.ThrowIfCancellationRequested();
        if (_graph is not null)
        {
            throw new InvalidOperationException("Audio capture is already running.");
        }

        _onFrame = onFrame;
        LastError = null;
        _captureCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);

        try
        {
            var settings = new AudioGraphSettings(AudioRenderCategory.Communications)
            {
                QuantumSizeSelectionMode = QuantumSizeSelectionMode.LowestLatency,
            };

            var graphResult = await AudioGraph.CreateAsync(settings);
            cancellationToken.ThrowIfCancellationRequested();
            if (graphResult.Status != AudioGraphCreationStatus.Success)
            {
                throw new InvalidOperationException($"AudioGraph creation failed: {graphResult.Status}");
            }

            _graph = graphResult.Graph;
            _outputNode = _graph.CreateFrameOutputNode();

            var inputResult = await _graph.CreateDeviceInputNodeAsync(MediaCategory.Communications);
            cancellationToken.ThrowIfCancellationRequested();
            if (inputResult.Status != AudioDeviceNodeCreationStatus.Success)
            {
                throw new InvalidOperationException($"audio input node creation failed: {inputResult.Status}");
            }

            _inputNode = inputResult.DeviceInputNode;
            _inputNode.AddOutgoingConnection(_outputNode);

            _graph.QuantumStarted += OnQuantumStarted;
            _graph.Start();
        }
        catch
        {
            await StopAsync().ConfigureAwait(false);
            throw;
        }
    }

    private async void OnQuantumStarted(AudioGraph sender, object args)
    {
        var handler = _onFrame;
        var output = _outputNode;
        var captureCancellation = _captureCancellation;
        if (handler is null || output is null || captureCancellation is null || !_frameGate.Wait(0))
        {
            return;
        }

        try
        {
            captureCancellation.Token.ThrowIfCancellationRequested();
            using var frame = output.GetFrame();
            byte[] pcm = DrainFrameToPcm(frame);
            if (pcm.Length == 0)
            {
                return;
            }

            _quantumCounter++;
            ulong timestamp = _quantumCounter * 10;
            await handler(new CapturedFrame(
                pcm,
                width: 0,
                height: 0,
                presentationTimestampMillis: timestamp)).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (captureCancellation.IsCancellationRequested)
        {
        }
        catch (Exception ex)
        {
            LastError = ex;
        }
        finally
        {
            _frameGate.Release();
        }
    }

    /// <summary>
    /// Copy the interleaved float PCM out of the audio frame's buffer. The exact
    /// IMemoryBufferByteAccess exposes the locked WinRT buffer without fabricating
    /// zero-filled samples.
    /// </summary>
    private static byte[] DrainFrameToPcm(global::Windows.Media.AudioFrame frame)
    {
        using var buffer = frame.LockBuffer(global::Windows.Media.AudioBufferAccessMode.Read);
        return WindowsMediaBufferReader.ReadAudioBuffer(buffer);
    }

    public async Task StopAsync()
    {
        Exception? stopError = null;
        _captureCancellation?.Cancel();
        if (_graph is not null)
        {
            _graph.QuantumStarted -= OnQuantumStarted;
            try
            {
                _graph.Stop();
            }
            catch (Exception ex)
            {
                stopError = ex;
            }
        }

        await _frameGate.WaitAsync().ConfigureAwait(false);
        try
        {
            _inputNode?.Dispose();
            _inputNode = null;
            _outputNode?.Dispose();
            _outputNode = null;
            _graph?.Dispose();
            _graph = null;
        }
        finally
        {
            _frameGate.Release();
        }

        _captureCancellation?.Dispose();
        _captureCancellation = null;
        _onFrame = null;

        if (stopError is not null)
        {
            throw stopError;
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }

        await StopAsync().ConfigureAwait(false);
        _disposed = true;
        _frameGate.Dispose();
    }
}
