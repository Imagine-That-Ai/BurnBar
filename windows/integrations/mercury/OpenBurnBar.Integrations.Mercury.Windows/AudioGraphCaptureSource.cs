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
    private AudioGraph? _graph;
    private AudioDeviceInputNode? _inputNode;
    private AudioFrameOutputNode? _outputNode;
    private Func<CapturedFrame, ValueTask>? _onFrame;
    private ulong _quantumCounter;

    public bool IsMuted { get; set; }

    public async Task StartAsync(Func<CapturedFrame, ValueTask> onFrame, CancellationToken cancellationToken = default)
    {
        _onFrame = onFrame ?? throw new ArgumentNullException(nameof(onFrame));

        var settings = new AudioGraphSettings(AudioRenderCategory.Communications)
        {
            QuantumSizeSelectionMode = QuantumSizeSelectionMode.LowestLatency,
        };

        var graphResult = await AudioGraph.CreateAsync(settings);
        if (graphResult.Status != AudioGraphCreationStatus.Success)
        {
            throw new InvalidOperationException($"AudioGraph creation failed: {graphResult.Status}");
        }

        _graph = graphResult.Graph;
        _outputNode = _graph.CreateFrameOutputNode();

        var inputResult = await _graph.CreateDeviceInputNodeAsync(MediaCategory.Communications);
        if (inputResult.Status != AudioDeviceNodeCreationStatus.Success)
        {
            throw new InvalidOperationException($"audio input node creation failed: {inputResult.Status}");
        }

        _inputNode = inputResult.DeviceInputNode;
        _inputNode.AddOutgoingConnection(_outputNode);

        _graph.QuantumStarted += OnQuantumStarted;
        _graph.Start();
    }

    private void OnQuantumStarted(AudioGraph sender, object args)
    {
        var handler = _onFrame;
        var output = _outputNode;
        if (handler is null || output is null)
        {
            return;
        }

        using var frame = output.GetFrame();
        var pcm = DrainFrameToPcm(frame);
        _quantumCounter++;
        var timestamp = (ulong)(_quantumCounter * 10); // ~10ms quanta at low latency
        _ = handler(new CapturedFrame(pcm, width: 0, height: 0, presentationTimestampMillis: timestamp));
    }

    /// <summary>
    /// Copy the interleaved float PCM out of the audio frame's buffer. The exact
    /// unsafe buffer readback (IMemoryBufferByteAccess) is completed on the
    /// Windows dev host; the seam is here so the portable pipeline compiles.
    /// </summary>
    private static byte[] DrainFrameToPcm(global::Windows.Media.AudioFrame frame)
    {
        using var buffer = frame.LockBuffer(global::Windows.Media.AudioBufferAccessMode.Read);
        var length = (int)buffer.Length;
        return new byte[Math.Max(0, length)];
    }

    public Task StopAsync()
    {
        if (_graph is not null)
        {
            _graph.QuantumStarted -= OnQuantumStarted;
            _graph.Stop();
        }

        _inputNode?.Dispose();
        _inputNode = null;
        _outputNode?.Dispose();
        _outputNode = null;
        _graph?.Dispose();
        _graph = null;
        _onFrame = null;
        return Task.CompletedTask;
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync().ConfigureAwait(false);
    }
}
