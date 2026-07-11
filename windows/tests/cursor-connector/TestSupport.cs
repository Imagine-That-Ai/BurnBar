using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using OpenBurnBar.App.CursorConnector;
using Xunit;

namespace OpenBurnBar.App.CursorConnector.Tests;

/// <summary>Fixture resolution + in-memory seam fakes shared by the connector tests.</summary>
internal static class TestSupport
{
    /// <summary>Reads a recorded fixture from the copied-to-output Fixtures directory.</summary>
    internal static string ReadFixture(string fileName)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", fileName);
        Assert.True(File.Exists(path), $"Missing fixture '{fileName}' at '{path}'.");
        return File.ReadAllText(path);
    }
}

/// <summary>A deterministic <see cref="IConnectorClock"/>.</summary>
internal sealed class FixedClock : IConnectorClock
{
    /// <summary>Creates a clock pinned to <paramref name="now"/>.</summary>
    internal FixedClock(DateTimeOffset now) => UtcNow = now;

    /// <inheritdoc />
    public DateTimeOffset UtcNow { get; set; }
}

/// <summary>An in-memory <see cref="ISecretStore"/>.</summary>
internal sealed class FakeSecretStore : ISecretStore
{
    private readonly Dictionary<string, string> _secrets = new(StringComparer.Ordinal);

    /// <inheritdoc />
    public string? TryRead(string account) => _secrets.TryGetValue(account, out var value) ? value : null;

    /// <inheritdoc />
    public void Set(string account, string value) => _secrets[account] = value;

    /// <inheritdoc />
    public void Delete(string account) => _secrets.Remove(account);
}

/// <summary>An in-memory, append/truncate-capable <see cref="ILogStreamSource"/>.</summary>
internal sealed class InMemoryLogStreamSource : ILogStreamSource
{
    private readonly Dictionary<string, byte[]> _files = new(StringComparer.Ordinal);

    /// <summary>Appends UTF-8 text to the backing buffer for <paramref name="path"/>.</summary>
    internal void Append(string path, string text)
    {
        var existing = _files.TryGetValue(path, out var bytes) ? bytes : Array.Empty<byte>();
        var addition = Encoding.UTF8.GetBytes(text);
        var combined = new byte[existing.Length + addition.Length];
        Buffer.BlockCopy(existing, 0, combined, 0, existing.Length);
        Buffer.BlockCopy(addition, 0, combined, existing.Length, addition.Length);
        _files[path] = combined;
    }

    /// <summary>Replaces the whole backing buffer (models a log rotation/truncation).</summary>
    internal void Replace(string path, string text) => _files[path] = Encoding.UTF8.GetBytes(text);

    /// <inheritdoc />
    public bool Exists(string path) => _files.ContainsKey(path);

    /// <inheritdoc />
    public long? Length(string path) => _files.TryGetValue(path, out var bytes) ? bytes.Length : null;

    /// <inheritdoc />
    public byte[] ReadFrom(string path, long offset)
    {
        if (!_files.TryGetValue(path, out var bytes) || offset >= bytes.Length)
        {
            return Array.Empty<byte>();
        }

        var start = (int)offset;
        var slice = new byte[bytes.Length - start];
        Buffer.BlockCopy(bytes, start, slice, 0, slice.Length);
        return slice;
    }
}

/// <summary>An in-memory <see cref="ICursorStateStore"/> that records writes.</summary>
internal sealed class FakeCursorStateStore : ICursorStateStore
{
    private readonly Dictionary<string, string> _items = new(StringComparer.Ordinal);

    /// <summary>The write log, in order.</summary>
    internal List<(string Key, string Value)> Writes { get; } = new();

    /// <summary>Seeds an ItemTable value.</summary>
    internal void Seed(string key, string value) => _items[key] = value;

    /// <inheritdoc />
    public string? TryReadItem(string key) => _items.TryGetValue(key, out var value) ? value : null;

    /// <inheritdoc />
    public void WriteItem(string key, string value)
    {
        _items[key] = value;
        Writes.Add((key, value));
    }
}

/// <summary>An in-memory <see cref="IConnectorFileSystem"/>.</summary>
internal sealed class InMemoryFileSystem : IConnectorFileSystem
{
    private readonly Dictionary<string, string> _files = new(StringComparer.Ordinal);

    /// <summary>The directories that were created.</summary>
    internal HashSet<string> Directories { get; } = new(StringComparer.Ordinal);

    /// <summary>Seeds a file.</summary>
    internal void Seed(string path, string content) => _files[path] = content;

    /// <summary>Reads a file directly (test assertion helper).</summary>
    internal string Peek(string path) => _files[path];

    /// <summary>Whether a file was written/seeded.</summary>
    internal bool Has(string path) => _files.ContainsKey(path);

    /// <inheritdoc />
    public bool FileExists(string path) => _files.ContainsKey(path);

    /// <inheritdoc />
    public string ReadAllText(string path) => _files[path];

    /// <inheritdoc />
    public void WriteAllText(string path, string content) => _files[path] = content;

    /// <inheritdoc />
    public void CreateDirectory(string path) => Directories.Add(path);

    /// <inheritdoc />
    public void CopyFile(string source, string destination) => _files[destination] = _files[source];
}

/// <summary>An <see cref="IRandomTokenSource"/> that emits a fixed byte pattern.</summary>
internal sealed class FixedRandomTokenSource : IRandomTokenSource
{
    private readonly byte _seed;

    /// <summary>Creates a source that fills every byte with <paramref name="seed"/>.</summary>
    internal FixedRandomTokenSource(byte seed) => _seed = seed;

    /// <inheritdoc />
    public byte[] NextBytes(int byteCount)
    {
        var bytes = new byte[byteCount];
        for (var i = 0; i < byteCount; i++)
        {
            bytes[i] = _seed;
        }

        return bytes;
    }
}

/// <summary>
/// A recording <see cref="IConnectorSessionSteps"/> that logs call order and can be
/// told to throw at one named step (to prove rollback ordering).
/// </summary>
internal sealed class RecordingSessionSteps : IConnectorSessionSteps
{
    private readonly string? _throwAt;
    private readonly bool _throwOnRestore;

    /// <summary>The ordered call log.</summary>
    internal List<string> Calls { get; } = new();

    /// <summary>Creates the fake; <paramref name="throwAt"/> names a step that throws.</summary>
    internal RecordingSessionSteps(string? throwAt = null, bool throwOnRestore = false)
    {
        _throwAt = throwAt;
        _throwOnRestore = throwOnRestore;
    }

    private void Record(string name)
    {
        Calls.Add(name);
        if (name == _throwAt)
        {
            throw new InvalidOperationException($"boom:{name}");
        }
    }

    /// <inheritdoc />
    public void ValidateConfiguration() => Record(nameof(ValidateConfiguration));

    /// <inheritdoc />
    public void EnsureSupportDirectory() => Record(nameof(EnsureSupportDirectory));

    /// <inheritdoc />
    public void RefreshSystemHealth() => Record(nameof(RefreshSystemHealth));

    /// <inheritdoc />
    public void GenerateRotationToken() => Record(nameof(GenerateRotationToken));

    /// <inheritdoc />
    public void StartSecretBroker() => Record(nameof(StartSecretBroker));

    /// <inheritdoc />
    public void WriteProxyScript() => Record(nameof(WriteProxyScript));

    /// <inheritdoc />
    public void WriteProxyConfig() => Record(nameof(WriteProxyConfig));

    /// <inheritdoc />
    public void StartProxy() => Record(nameof(StartProxy));

    /// <inheritdoc />
    public void StartTunnel() => Record(nameof(StartTunnel));

    /// <inheritdoc />
    public void ApplyCursorSettings() => Record(nameof(ApplyCursorSettings));

    /// <inheritdoc />
    public void VerifyPublicEndpoint() => Record(nameof(VerifyPublicEndpoint));

    /// <inheritdoc />
    public void StopSecretBroker() => Calls.Add(nameof(StopSecretBroker));

    /// <inheritdoc />
    public void StopProxy() => Calls.Add(nameof(StopProxy));

    /// <inheritdoc />
    public void StopTunnel() => Calls.Add(nameof(StopTunnel));

    /// <inheritdoc />
    public void RestoreCursorSettings()
    {
        Calls.Add(nameof(RestoreCursorSettings));
        if (_throwOnRestore)
        {
            throw new InvalidOperationException("restore-failed");
        }
    }
}
